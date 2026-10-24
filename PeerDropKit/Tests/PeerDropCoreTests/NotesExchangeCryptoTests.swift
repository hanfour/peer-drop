import XCTest
import CryptoKit
@testable import PeerDropCore
import PeerDropProtocol

final class NotesExchangeCryptoTests: XCTestCase {

    // MARK: - Fixtures

    private let accountId = "ABCD1234"
    private let keyLow = Data(repeating: 0x01, count: 32)
    private let keyHigh = Data(repeating: 0xF0, count: 32)
    private let nonceX = Data(repeating: 0xAA, count: 32)
    private let nonceY = Data(repeating: 0x11, count: 32)

    private func randomBytes(_ n: Int) -> Data {
        var rng = SystemRandomNumberGenerator()
        return Data((0..<n).map { _ in UInt8.random(in: .min ... .max, using: &rng) })
    }

    /// The revealer is "the peer": it signs with its own view (mine = its key).
    fileprivate struct Party {
        var signing: Curve25519.Signing.PrivateKey
        var handshakeKey: Data
        var nonce: Data
        var account: NotesExchangeSession.AccountSnapshot

        static func make(accountId: String) -> Party {
            let s = Curve25519.Signing.PrivateKey()
            var rng = SystemRandomNumberGenerator()
            func bytes() -> Data { Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &rng) }) }
            return Party(signing: s, handshakeKey: bytes(), nonce: bytes(),
                         account: NotesExchangeSession.AccountSnapshot(accountId: accountId, signingKey: s.publicKey.rawRepresentation)!)
        }
    }

    private func makeParties() -> (revealer: Party, verifier: Party) {
        (Party.make(accountId: "ZZ99XX11"), Party.make(accountId: "ABCD1234"))
    }

    private func reveal(by r: Party, to v: Party,
                        nonces: NotesExchangePair? = nil) throws -> NotesExchangePayload {
        try NotesExchangeCrypto.makeReveal(
            account: r.account,
            handshakeKeys: NotesExchangePair(mine: r.handshakeKey, theirs: v.handshakeKey),
            nonces: nonces ?? NotesExchangePair(mine: r.nonce, theirs: v.nonce),
            signer: { try r.signing.signature(for: $0) })
    }

    private func verify(_ p: NotesExchangePayload, at v: Party, from r: Party) -> Bool {
        NotesExchangeCrypto.verifyReveal(
            payload: p,
            handshakeKeys: NotesExchangePair(mine: v.handshakeKey, theirs: r.handshakeKey),
            nonces: NotesExchangePair(mine: v.nonce, theirs: r.nonce))
    }

    // MARK: - Digest (role-ordered: revealer first)

    private func digest(_ id: String, rk: Data, vk: Data, rn: Data, vn: Data) -> Data? {
        NotesExchangeCrypto.revealDigest(accountId: id, revealerKey: rk, verifierKey: vk,
                                         revealerNonce: rn, verifierNonce: vn)
    }

    func testDigestMatchesSpecifiedLayout() throws {
        // SHA256(domain ‖ id ‖ revealerKey ‖ verifierKey ‖ revealerNonce ‖ verifierNonce), no sorting.
        var m = Data("peerdrop-notes-exchange-v1".utf8)
        m.append(Data(accountId.utf8))
        m.append(keyHigh); m.append(keyLow)
        m.append(nonceX); m.append(nonceY)
        XCTAssertEqual(digest(accountId, rk: keyHigh, vk: keyLow, rn: nonceX, vn: nonceY),
                       Data(SHA256.hash(data: m)))
    }

    func testDigestIsRoleOrdered() throws {
        // Swapping revealer and verifier must change the digest (no symmetric sorting).
        let a = try XCTUnwrap(digest(accountId, rk: keyLow, vk: keyHigh, rn: nonceX, vn: nonceY))
        let b = try XCTUnwrap(digest(accountId, rk: keyHigh, vk: keyLow, rn: nonceY, vn: nonceX))
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.count, 32)
    }

    func testDigestNoncesAreNotSortedByValue() throws {
        let a = digest(accountId, rk: keyLow, vk: keyHigh, rn: nonceX, vn: nonceY)
        let b = digest(accountId, rk: keyLow, vk: keyHigh, rn: nonceY, vn: nonceX)
        XCTAssertNotNil(a); XCTAssertNotNil(b)
        XCTAssertNotEqual(a, b)
        let c = digest(accountId, rk: keyLow, vk: keyHigh, rn: nonceX, vn: nonceY)
        let e = digest(accountId, rk: keyHigh, vk: keyLow, rn: nonceX, vn: nonceY)
        XCTAssertNotEqual(c, e, "keys are not sorted either")
    }

    func testWrongSizeFieldsRejected() {
        let short = Data(repeating: 1, count: 31), long = Data(repeating: 1, count: 33)
        for bad in [Data(), short, long] {
            XCTAssertNil(digest(accountId, rk: bad, vk: keyHigh, rn: nonceX, vn: nonceY))
            XCTAssertNil(digest(accountId, rk: keyLow, vk: bad, rn: nonceX, vn: nonceY))
            XCTAssertNil(digest(accountId, rk: keyLow, vk: keyHigh, rn: bad, vn: nonceY))
            XCTAssertNil(digest(accountId, rk: keyLow, vk: keyHigh, rn: nonceX, vn: bad))
        }
        for badId in ["", "ABCD123", "ABCD12345", "abcd1234", "ABCD-234", "ABCDI234", "ＡBCD1234", "ABCD1234\u{0}"] {
            XCTAssertNil(digest(badId, rk: keyLow, vk: keyHigh, rn: nonceX, vn: nonceY), badId)
        }
    }

    func testIdenticalKeysRejected() {
        XCTAssertNil(digest(accountId, rk: keyLow, vk: keyLow, rn: nonceX, vn: nonceY))
    }

    func testMakeNonceIs32RandomBytes() {
        let a = NotesExchangeCrypto.makeNonce(), b = NotesExchangeCrypto.makeNonce()
        XCTAssertEqual(a.count, 32); XCTAssertEqual(b.count, 32)
        XCTAssertNotEqual(a, b)
    }

    func testMakeNonceUsesInjectedGenerator() {
        var g1 = FixedRNG(seed: 7), g2 = FixedRNG(seed: 7)
        XCTAssertEqual(NotesExchangeCrypto.makeNonce(using: &g1), NotesExchangeCrypto.makeNonce(using: &g2))
        XCTAssertEqual(NotesExchangeCrypto.makeNonce(using: &g1).count, 32)
    }

    // MARK: - Sign / verify

    func testSignatureVerifies() throws {
        let (r, v) = makeParties()
        let p = try reveal(by: r, to: v)
        XCTAssertEqual(p.phase, "reveal")
        XCTAssertEqual(p.accountId, r.account.accountId)
        XCTAssertEqual(p.signingKey, r.account.signingKey)
        XCTAssertEqual(p.signature?.count, 64)
        XCTAssertNil(p.nonce, "reveal does not repeat the nonce; the verifier uses the intents' nonces")
        XCTAssertTrue(verify(p, at: v, from: r))
    }

    func testTamperedSignatureFails() throws {
        let (r, v) = makeParties()
        var p = try reveal(by: r, to: v)
        var sig = try XCTUnwrap(p.signature); sig[5] ^= 0x01; p.signature = sig
        XCTAssertFalse(verify(p, at: v, from: r))
    }

    func testSignatureFailsOnDifferentAccountId() throws {
        let (r, v) = makeParties()
        var p = try reveal(by: r, to: v)
        p.accountId = "ZZ99XX12"
        XCTAssertFalse(verify(p, at: v, from: r))
    }

    func testLowercaseAccountIdRejected() throws {
        let (r, v) = makeParties()
        var p = try reveal(by: r, to: v)
        p.accountId = r.account.accountId.lowercased()
        XCTAssertFalse(verify(p, at: v, from: r))
        XCTAssertNil(NotesExchangeSession.AccountSnapshot(accountId: "zz99xx11", signingKey: r.account.signingKey))
    }

    func testSignatureFailsOnDifferentNonce() throws {
        // Cross-connection replay: a reveal signed for an earlier connection's
        // nonces must not verify against this connection's nonces.
        let (r, v) = makeParties()
        let old = try reveal(by: r, to: v)
        var fresh = v; fresh.nonce = randomBytes(32)
        XCTAssertFalse(verify(old, at: fresh, from: r))
        var freshR = r; freshR.nonce = randomBytes(32)
        XCTAssertFalse(verify(old, at: v, from: freshR))
    }

    func testSignatureFailsWhenNoncesSwapped() throws {
        let (r, v) = makeParties()
        let p = try reveal(by: r, to: v)
        XCTAssertFalse(NotesExchangeCrypto.verifyReveal(
            payload: p,
            handshakeKeys: NotesExchangePair(mine: v.handshakeKey, theirs: r.handshakeKey),
            nonces: NotesExchangePair(mine: r.nonce, theirs: v.nonce)))
    }

    func testSignatureFailsOnDifferentHandshakeKey() throws {
        let (r, v) = makeParties()
        let p = try reveal(by: r, to: v)
        var other = v; other.handshakeKey = randomBytes(32)
        XCTAssertFalse(verify(p, at: other, from: r), "different verifier key")
        var otherR = r; otherR.handshakeKey = randomBytes(32)
        XCTAssertFalse(verify(p, at: v, from: otherR), "different revealer key")
    }

    func testSignatureFailsWithDifferentSigningKey() throws {
        let (r, v) = makeParties()
        var p = try reveal(by: r, to: v)
        p.signingKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        XCTAssertFalse(verify(p, at: v, from: r))
    }

    func testVerifyRejectsMalformedPayloads() throws {
        let (r, v) = makeParties()
        let good = try reveal(by: r, to: v)
        var cases: [NotesExchangePayload] = []
        var p = good; p.phase = "intent"; cases.append(p)
        p = good; p.accountId = nil; cases.append(p)
        p = good; p.signingKey = nil; cases.append(p)
        p = good; p.signature = nil; cases.append(p)
        p = good; p.signingKey = good.signingKey! + Data([0]); cases.append(p)
        p = good; p.signingKey = good.signingKey!.prefix(31); cases.append(p)
        p = good; p.signature = good.signature! + Data([0]); cases.append(p)
        p = good; p.signature = good.signature!.prefix(63); cases.append(p)
        p = good; p.accountId = good.accountId! + " "; cases.append(p)
        for c in cases { XCTAssertFalse(verify(c, at: v, from: r), "\(c)") }
        // Wrong-size keys / nonces in the verifier's own inputs.
        XCTAssertFalse(NotesExchangeCrypto.verifyReveal(payload: good,
            handshakeKeys: NotesExchangePair(mine: v.handshakeKey.prefix(31), theirs: r.handshakeKey),
            nonces: NotesExchangePair(mine: v.nonce, theirs: r.nonce)))
        XCTAssertFalse(NotesExchangeCrypto.verifyReveal(payload: good,
            handshakeKeys: NotesExchangePair(mine: v.handshakeKey, theirs: r.handshakeKey),
            nonces: NotesExchangePair(mine: v.nonce, theirs: r.nonce + Data([0]))))
    }

    func testMakeRevealRejectsBadSignerOutput() {
        let (r, v) = makeParties()
        let pairK = NotesExchangePair(mine: r.handshakeKey, theirs: v.handshakeKey)
        let pairN = NotesExchangePair(mine: r.nonce, theirs: v.nonce)
        // Wrong length.
        XCTAssertThrowsError(try NotesExchangeCrypto.makeReveal(account: r.account, handshakeKeys: pairK, nonces: pairN, signer: { _ in Data(repeating: 0, count: 63) }))
        // Signed by a key that is not the account's signing key.
        let wrong = Curve25519.Signing.PrivateKey()
        XCTAssertThrowsError(try NotesExchangeCrypto.makeReveal(account: r.account, handshakeKeys: pairK, nonces: pairN, signer: { try wrong.signature(for: $0) }))
        // Signer error propagates.
        struct Boom: Error {}
        XCTAssertThrowsError(try NotesExchangeCrypto.makeReveal(account: r.account, handshakeKeys: pairK, nonces: pairN, signer: { _ in throw Boom() }))
        // Bad sizes.
        XCTAssertThrowsError(try NotesExchangeCrypto.makeReveal(account: r.account, handshakeKeys: NotesExchangePair(mine: r.handshakeKey, theirs: r.handshakeKey), nonces: pairN, signer: { try r.signing.signature(for: $0) }))
        XCTAssertThrowsError(try NotesExchangeCrypto.makeReveal(account: r.account, handshakeKeys: pairK, nonces: NotesExchangePair(mine: r.nonce.prefix(16), theirs: v.nonce), signer: { try r.signing.signature(for: $0) }))
    }

    // MARK: - Reflection / cross-connection (role-ordered digest)

    func testOwnRevealReflectedBackDoesNotVerify() throws {
        // I (r) sign a reveal for v; v echoes it back to me. Verifying at r treats
        // v as the revealer, so the role-ordered digest differs → reject by signature.
        let (r, v) = makeParties()
        let mine = try reveal(by: r, to: v)
        XCTAssertTrue(verify(mine, at: v, from: r), "sanity: verifies at the intended verifier")
        XCTAssertFalse(verify(mine, at: r, from: v), "reflection to the signer must fail")
    }

    func testRevealVerifiesOnlyOnItsOwnConnection() throws {
        // A's reveal for B verifies at B but not at a third connection C (other keys/nonces),
        // nor at C pretending to be on a connection with A.
        let a = Party.make(accountId: "AAAA0001"), b = Party.make(accountId: "BBBB0001")
        let c = Party.make(accountId: "CCCC0001")
        let p = try reveal(by: a, to: b)
        XCTAssertTrue(verify(p, at: b, from: a))
        XCTAssertFalse(verify(p, at: c, from: a))
        var aSeenByC = a; aSeenByC.nonce = c.nonce
        XCTAssertFalse(verify(p, at: c, from: aSeenByC))
    }

    // MARK: - Small-order / degenerate keys and signatures

    func testSmallOrderListIsComplete() {
        XCTAssertEqual(NotesExchangeCrypto.smallOrderSigningKeys.count, 14, "8 canonical + 6 non-canonical encodings")
        XCTAssertEqual(Set(NotesExchangeCrypto.smallOrderSigningKeys).count, 14)
        XCTAssertTrue(NotesExchangeCrypto.smallOrderSigningKeys.allSatisfy { $0.count == 32 })
    }

    private static let smallOrderHex: [String] = [
        "0100000000000000000000000000000000000000000000000000000000000000", // identity (order 1)
        "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", // (0,-1) order 2
        "0000000000000000000000000000000000000000000000000000000000000000", // order 4
        "0000000000000000000000000000000000000000000000000000000000000080", // order 4
        "26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc05", // order 8
        "26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc85", // order 8
        "c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac037a", // order 8
        "c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac03fa", // order 8
        "0100000000000000000000000000000000000000000000000000000000000080", // identity, x=-0
        "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", // (0,-1), x=-0
        "edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", // y=p (≡0)
        "edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", // y=p, sign 1
        "eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", // y=p+1 (≡1)
        "eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", // y=p+1, sign 1
    ]

    private static func hex(_ s: String) -> Data {
        var d = Data(); var i = s.startIndex
        while i < s.endIndex { let j = s.index(i, offsetBy: 2); d.append(UInt8(s[i..<j], radix: 16)!); i = j }
        return d
    }

    private func assertSmallOrderRejected(_ index: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let key = Self.hex(Self.smallOrderHex[index])
        XCTAssertTrue(NotesExchangeCrypto.smallOrderSigningKeys.contains(key), "constant contains #\(index)", file: file, line: line)
        XCTAssertNil(NotesExchangeSession.AccountSnapshot(accountId: "ABCD1234", signingKey: key), file: file, line: line)
        let (r, v) = makeParties()
        // Forged reveal with R = identity, S = 0: verifies for ANY message under a small-order key
        // in lenient verifiers. Also try a few other degenerate signatures.
        var forged = Data([0x01]) + Data(repeating: 0, count: 63)
        for sig in [forged, Data(repeating: 0, count: 64), key + Data(repeating: 0, count: 32)] {
            forged = sig
            let p = NotesExchangePayload(phase: "reveal", accountId: r.account.accountId, signingKey: key, signature: forged)
            XCTAssertFalse(verify(p, at: v, from: r), "small-order key #\(index)", file: file, line: line)
        }
    }

    func testSmallOrderKey0Rejected() throws { try assertSmallOrderRejected(0) }
    func testSmallOrderKey1Rejected() throws { try assertSmallOrderRejected(1) }
    func testSmallOrderKey2Rejected() throws { try assertSmallOrderRejected(2) }
    func testSmallOrderKey3Rejected() throws { try assertSmallOrderRejected(3) }
    func testSmallOrderKey4Rejected() throws { try assertSmallOrderRejected(4) }
    func testSmallOrderKey5Rejected() throws { try assertSmallOrderRejected(5) }
    func testSmallOrderKey6Rejected() throws { try assertSmallOrderRejected(6) }
    func testSmallOrderKey7Rejected() throws { try assertSmallOrderRejected(7) }
    func testSmallOrderKey8Rejected() throws { try assertSmallOrderRejected(8) }
    func testSmallOrderKey9Rejected() throws { try assertSmallOrderRejected(9) }
    func testSmallOrderKey10Rejected() throws { try assertSmallOrderRejected(10) }
    func testSmallOrderKey11Rejected() throws { try assertSmallOrderRejected(11) }
    func testSmallOrderKey12Rejected() throws { try assertSmallOrderRejected(12) }
    func testSmallOrderKey13Rejected() throws { try assertSmallOrderRejected(13) }

    func testIdentityKeyWithIdentitySignatureRejected() {
        // The reviewer's exact case.
        let (r, v) = makeParties()
        let p = NotesExchangePayload(phase: "reveal", accountId: r.account.accountId,
                                     signingKey: Data([0x01]) + Data(repeating: 0, count: 31),
                                     signature: Data([0x01]) + Data(repeating: 0, count: 63))
        XCTAssertFalse(verify(p, at: v, from: r))
    }

    func testAllZeroSignatureRejected() throws {
        let (r, v) = makeParties()
        var p = try reveal(by: r, to: v)
        p.signature = Data(repeating: 0, count: 64)
        XCTAssertFalse(verify(p, at: v, from: r))
        XCTAssertThrowsError(try NotesExchangeCrypto.makeReveal(
            account: r.account,
            handshakeKeys: NotesExchangePair(mine: r.handshakeKey, theirs: v.handshakeKey),
            nonces: NotesExchangePair(mine: r.nonce, theirs: v.nonce),
            signer: { _ in Data(repeating: 0, count: 64) }))
    }

    func testAccountSnapshotValidation() {
        let sk = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        XCTAssertNotNil(NotesExchangeSession.AccountSnapshot(accountId: "ABCD1234", signingKey: sk))
        XCTAssertNil(NotesExchangeSession.AccountSnapshot(accountId: "ABCD123", signingKey: sk))
        XCTAssertNil(NotesExchangeSession.AccountSnapshot(accountId: "abcd1234", signingKey: sk))
        XCTAssertNil(NotesExchangeSession.AccountSnapshot(accountId: "ABCD1234", signingKey: sk.prefix(31)))
    }
}

/// Deterministic generator for nonce-injection tests (NOT for production).
struct FixedRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
