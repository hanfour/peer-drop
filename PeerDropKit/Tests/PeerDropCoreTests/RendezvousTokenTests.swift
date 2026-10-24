import XCTest
import CryptoKit
import PeerDropSecurity
@testable import PeerDropCore

/// In-memory X25519 identity — never touches the keychain.
final class RendezvousTestIdentity: LocalChannelIdentity {
    let privateKey: Curve25519.KeyAgreement.PrivateKey
    init(_ privateKey: Curve25519.KeyAgreement.PrivateKey = .init()) { self.privateKey = privateKey }
    var publicKey: Curve25519.KeyAgreement.PublicKey { privateKey.publicKey }
    var raw: Data { publicKey.rawRepresentation }
    func deriveSharedSecret(with peerPublicKey: Curve25519.KeyAgreement.PublicKey) throws -> SharedSecret {
        try privateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
    }
}

/// Fixed-secret fake provider for known-answer tests.
struct FixedSecretProvider: RendezvousSecretProvider {
    let localAgreementPublicKey: Data
    let secret: Data
    func sharedSecret(withPeerAgreementKey peerKey: Data) throws -> SymmetricKey {
        SymmetricKey(data: secret)
    }
}

extension SymmetricKey {
    var rawData: Data { withUnsafeBytes { Data($0) } }
}

final class RendezvousTokenTests: XCTestCase {

    private func pair() -> (RendezvousTestIdentity, RendezvousTestIdentity) {
        (RendezvousTestIdentity(), RendezvousTestIdentity())
    }

    private func date(_ seconds: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(seconds)) }

    // MARK: - Derivation

    func testKnownAnswerVector() throws {
        // Python reference: HKDF-SHA256(ikm=0x11*32, salt="peerdrop-rv-v1",
        // info=0x02*32 || 0x03*32 || UInt64BE(20000)), L=32.
        let a = Data(repeating: 0x02, count: 32), b = Data(repeating: 0x03, count: 32)
        let secret = SymmetricKey(data: Data(repeating: 0x11, count: 32))
        let t1 = try RendezvousToken.token(sharedSecret: secret, myKey: a, peerKey: b, day: 20000)
        let t2 = try RendezvousToken.token(sharedSecret: secret, myKey: b, peerKey: a, day: 20000)
        XCTAssertEqual(t1.hexString, "dd678b50ee0abe32b90e5d39219705c379ba9d1b449035dc277e2d6e42cb4665")
        XCTAssertEqual(t1, t2)
        XCTAssertEqual(try RendezvousToken.encoded(t1), "3WeLUO4KvjK5Dl05IZcFw3m6nRtEkDXcJ34tbkLLRmU")
    }

    func testBothSidesComputeSameToken() throws {
        let (alice, bob) = pair()
        let pa = IdentityRendezvousSecretProvider(identity: alice)
        let pb = IdentityRendezvousSecretProvider(identity: bob)
        let ta = try RendezvousToken.token(provider: pa, peerKey: bob.raw, day: 20_385)
        let tb = try RendezvousToken.token(provider: pb, peerKey: alice.raw, day: 20_385)
        XCTAssertEqual(ta.count, 32)
        XCTAssertEqual(ta, tb)
    }

    func testDifferentDayDifferentToken() throws {
        let (alice, bob) = pair()
        let p = IdentityRendezvousSecretProvider(identity: alice)
        let t1 = try RendezvousToken.token(provider: p, peerKey: bob.raw, day: 20_385)
        let t2 = try RendezvousToken.token(provider: p, peerKey: bob.raw, day: 20_386)
        XCTAssertNotEqual(t1, t2)
    }

    func testKeyChangeGivesDifferentToken() throws {
        let (alice, bob) = pair()
        let bob2 = RendezvousTestIdentity()
        let p = IdentityRendezvousSecretProvider(identity: alice)
        let t1 = try RendezvousToken.token(provider: p, peerKey: bob.raw, day: 20_385)
        let t2 = try RendezvousToken.token(provider: p, peerKey: bob2.raw, day: 20_385)
        XCTAssertNotEqual(t1, t2)
        // And a third party pairing with bob gets a different token too.
        let carol = RendezvousTestIdentity()
        let t3 = try RendezvousToken.token(provider: IdentityRendezvousSecretProvider(identity: carol),
                                           peerKey: bob.raw, day: 20_385)
        XCTAssertNotEqual(t1, t3)
    }

    func testDomainSeparationFromLocalSecureChannelAndSignalingKey() throws {
        let (alice, bob) = pair()
        let shared = try alice.deriveSharedSecret(with: bob.publicKey)
        // LocalSecureChannel root: salt "", info "PeerDrop-LocalE2E-v1".
        let localRoot = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: Data(), sharedInfo: Data("PeerDrop-LocalE2E-v1".utf8), outputByteCount: 32)
        let p = IdentityRendezvousSecretProvider(identity: alice)
        let token = try RendezvousToken.token(provider: p, peerKey: bob.raw, day: 20_385)
        let sigKey = try RendezvousSignalingCrypto.signalingKey(provider: p, peerKey: bob.raw, day: 20_385)
        XCTAssertNotEqual(token, localRoot.rawData)
        XCTAssertNotEqual(token, sigKey.rawData)
        XCTAssertNotEqual(sigKey.rawData, localRoot.rawData)
        // Also distinct from SessionKeyManager's static-DH key.
        let sessionKey = try SessionKeyManager.deriveSessionKey(myPrivateKey: alice.privateKey, peerPublicKey: bob.publicKey)
        XCTAssertNotEqual(token, sessionKey.rawData)
    }

    func testProviderSecretMatchesCryptoKitSharedSecretHKDF() throws {
        // Using the raw DH bytes as IKM must equal SharedSecret.hkdfDerivedSymmetricKey.
        let (alice, bob) = pair()
        let p = IdentityRendezvousSecretProvider(identity: alice)
        let shared = try alice.deriveSharedSecret(with: bob.publicKey)
        let info = try RendezvousKeyOrder.pairInfo(myKey: alice.raw, peerKey: bob.raw, day: 7)
        let expected = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: Data("peerdrop-rv-v1".utf8), sharedInfo: info, outputByteCount: 32)
        XCTAssertEqual(try RendezvousToken.token(provider: p, peerKey: bob.raw, day: 7), expected.rawData)
    }

    func testInfoLayoutIsSortedKeysThenDayBigEndian() throws {
        let a = Data(repeating: 0x05, count: 32), b = Data([0x01] + Array(repeating: 0xFF, count: 31))
        let info = try RendezvousKeyOrder.pairInfo(myKey: a, peerKey: b, day: 0x0102)
        XCTAssertEqual(info.count, 72)
        XCTAssertEqual(info.prefix(32), b)          // b < a lexicographically
        XCTAssertEqual(info.subdata(in: 32..<64), a)
        XCTAssertEqual(Array(info.suffix(8)), [0, 0, 0, 0, 0, 0, 0x01, 0x02])
        XCTAssertTrue(try RendezvousKeyOrder.isLocalSmaller(myKey: b, peerKey: a))
        XCTAssertFalse(try RendezvousKeyOrder.isLocalSmaller(myKey: a, peerKey: b))
    }

    func testEqualKeysRejected() {
        let alice = RendezvousTestIdentity()
        let p = IdentityRendezvousSecretProvider(identity: alice)
        XCTAssertThrowsError(try RendezvousToken.token(provider: p, peerKey: alice.raw, day: 1)) {
            XCTAssertEqual($0 as? RendezvousCryptoError, .identicalPublicKeys)
        }
        let k = Data(repeating: 9, count: 32)
        XCTAssertThrowsError(try RendezvousToken.token(
            sharedSecret: SymmetricKey(size: .bits256), myKey: k, peerKey: k, day: 1)) {
            XCTAssertEqual($0 as? RendezvousCryptoError, .identicalPublicKeys)
        }
    }

    func testBadInputsRejected() {
        let s = SymmetricKey(size: .bits256)
        let k = Data(repeating: 9, count: 32)
        XCTAssertThrowsError(try RendezvousToken.token(sharedSecret: s, myKey: Data(count: 31), peerKey: k, day: 1))
        XCTAssertThrowsError(try RendezvousToken.token(sharedSecret: s, myKey: k, peerKey: Data(count: 33), day: 1))
        XCTAssertThrowsError(try RendezvousToken.token(sharedSecret: s, myKey: k, peerKey: Data(count: 32), day: -1))
        // All-zero DH output (low-order point) is refused.
        XCTAssertThrowsError(try RendezvousToken.token(
            sharedSecret: SymmetricKey(data: Data(count: 32)), myKey: k, peerKey: Data(count: 32), day: 1)) {
            XCTAssertEqual($0 as? RendezvousCryptoError, .degenerateSharedSecret)
        }
        // A provider returning an all-zero secret is refused as well.
        let zero = FixedSecretProvider(localAgreementPublicKey: k, secret: Data(count: 32))
        XCTAssertThrowsError(try RendezvousToken.token(provider: zero, peerKey: Data(repeating: 1, count: 32), day: 1))
    }

    // MARK: - Day / boundary

    func testDayIsFloorOfUnixSecondsOverDay() {
        XCTAssertEqual(RendezvousToken.day(at: date(0)), 0)
        XCTAssertEqual(RendezvousToken.day(at: date(86_399)), 0)
        XCTAssertEqual(RendezvousToken.day(at: date(86_400)), 1)
        XCTAssertEqual(RendezvousToken.day(at: Date(timeIntervalSince1970: 86_399.999)), 0)
        XCTAssertEqual(RendezvousToken.day(at: date(1_800_000_000)), 20_833)
    }

    func testDaysToJoinBoundaries() {
        let d = 20_000, midnight = d * 86_400, next = (d + 1) * 86_400
        // Mid-day: one token.
        XCTAssertEqual(RendezvousToken.daysToJoin(now: date(midnight + 43_200)), [d])
        // Previous-day token kept while now < midnight + 600.
        XCTAssertEqual(RendezvousToken.daysToJoin(now: date(midnight)), [d - 1, d])
        XCTAssertEqual(RendezvousToken.daysToJoin(now: date(midnight + 599)), [d - 1, d])
        XCTAssertEqual(RendezvousToken.daysToJoin(now: Date(timeIntervalSince1970: TimeInterval(midnight) + 599.999)), [d - 1, d])
        XCTAssertEqual(RendezvousToken.daysToJoin(now: date(midnight + 600)), [d])
        // Next-day token joined once now >= nextMidnight - 600.
        XCTAssertEqual(RendezvousToken.daysToJoin(now: date(next - 601)), [d])
        XCTAssertEqual(RendezvousToken.daysToJoin(now: Date(timeIntervalSince1970: TimeInterval(next - 600) - 0.001)), [d])
        XCTAssertEqual(RendezvousToken.daysToJoin(now: date(next - 600)), [d, d + 1])
        XCTAssertEqual(RendezvousToken.daysToJoin(now: date(next - 1)), [d, d + 1])
        // Day 0 has no previous day.
        XCTAssertEqual(RendezvousToken.daysToJoin(now: date(0)), [0])
    }

    func testTokensToJoinNormallyOneAndTwoNearBoundary() throws {
        let (alice, bob) = pair()
        let pa = IdentityRendezvousSecretProvider(identity: alice)
        let pb = IdentityRendezvousSecretProvider(identity: bob)
        let d = 20_385
        let noon = try RendezvousToken.tokensToJoin(now: date(d * 86_400 + 43_200), provider: pa, peerKey: bob.raw)
        XCTAssertEqual(noon.count, 1)
        XCTAssertEqual(noon[0].day, d)
        XCTAssertEqual(noon[0].token, try RendezvousToken.token(provider: pa, peerKey: bob.raw, day: d))

        // Alice is 9 minutes behind midnight, Bob 9 minutes past (clock skew 18 min):
        // they still share one token.
        let aLate = try RendezvousToken.tokensToJoin(now: date((d + 1) * 86_400 - 540), provider: pa, peerKey: bob.raw)
        let bEarly = try RendezvousToken.tokensToJoin(now: date((d + 1) * 86_400 + 540), provider: pb, peerKey: alice.raw)
        XCTAssertEqual(aLate.map(\.day), [d, d + 1])
        XCTAssertEqual(bEarly.map(\.day), [d, d + 1])
        XCTAssertEqual(aLate.map(\.token), bEarly.map(\.token))
    }

    // MARK: - Encoding

    func testEncodedIsCanonicalBase64URLAndRoundTrips() throws {
        for _ in 0..<200 {
            let t = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            let s = try RendezvousToken.encoded(t)
            XCTAssertEqual(s.count, 43)
            XCTAssertNil(s.firstIndex(where: { !($0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")) }))
            XCTAssertEqual(RendezvousToken.decodeCanonical(s), t)
        }
        XCTAssertThrowsError(try RendezvousToken.encoded(Data(count: 31)))
    }

    func testDecodeCanonicalRejectsNonCanonical() throws {
        // Worker vectors' tokens decode.
        XCTAssertEqual(RendezvousToken.decodeCanonical("AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE"), Data(repeating: 1, count: 32))
        XCTAssertNil(RendezvousToken.decodeCanonical("AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQF")) // non-zero trailing bits
        XCTAssertNil(RendezvousToken.decodeCanonical("AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=")) // padding
        XCTAssertNil(RendezvousToken.decodeCanonical("AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ+")) // std alphabet
        XCTAssertNil(RendezvousToken.decodeCanonical("AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ")) // 31.x bytes
        XCTAssertNil(RendezvousToken.decodeCanonical(""))
        XCTAssertNil(RendezvousToken.decodeCanonical(" AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE"))
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
