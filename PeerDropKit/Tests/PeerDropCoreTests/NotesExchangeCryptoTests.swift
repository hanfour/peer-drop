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

    // MARK: - Digest

    func testDigestIsOrderIndependent() throws {
        // Each nonce stays paired with the key of the party that produced it.
        let a = try XCTUnwrap(NotesExchangeCrypto.revealDigest(accountId: accountId, keyA: keyLow, keyB: keyHigh, nonceA: nonceX, nonceB: nonceY))
        let b = try XCTUnwrap(NotesExchangeCrypto.revealDigest(accountId: accountId, keyA: keyHigh, keyB: keyLow, nonceA: nonceY, nonceB: nonceX))
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 32)
    }

    func testDigestMatchesSpecifiedLayout() throws {
        // keyHigh's owner produced nonceY (the lexicographically SMALLER nonce):
        // nonces must follow the owning key's order, not their own byte order.
        var m = Data("peerdrop-notes-exchange-v1".utf8)
        m.append(Data(accountId.utf8))
        m.append(keyLow); m.append(keyHigh)
        m.append(nonceX)  // owner = keyLow
        m.append(nonceY)  // owner = keyHigh
        let expected = Data(SHA256.hash(data: m))
        XCTAssertEqual(NotesExchangeCrypto.revealDigest(accountId: accountId, keyA: keyHigh, keyB: keyLow, nonceA: nonceY, nonceB: nonceX), expected)
        XCTAssertEqual(NotesExchangeCrypto.revealDigest(accountId: accountId, keyA: keyLow, keyB: keyHigh, nonceA: nonceX, nonceB: nonceY), expected)
    }

    func testDigestNoncesAreNotSortedByValue() throws {
        // Swapping which party owns which nonce must change the digest.
        let a = NotesExchangeCrypto.revealDigest(accountId: accountId, keyA: keyLow, keyB: keyHigh, nonceA: nonceX, nonceB: nonceY)
        let b = NotesExchangeCrypto.revealDigest(accountId: accountId, keyA: keyLow, keyB: keyHigh, nonceA: nonceY, nonceB: nonceX)
        XCTAssertNotNil(a); XCTAssertNotNil(b)
        XCTAssertNotEqual(a, b)
    }

    func testWrongSizeFieldsRejected() {
        let short = Data(repeating: 1, count: 31), long = Data(repeating: 1, count: 33)
        for bad in [Data(), short, long] {
            XCTAssertNil(NotesExchangeCrypto.revealDigest(accountId: accountId, keyA: bad, keyB: keyHigh, nonceA: nonceX, nonceB: nonceY))
            XCTAssertNil(NotesExchangeCrypto.revealDigest(accountId: accountId, keyA: keyLow, keyB: bad, nonceA: nonceX, nonceB: nonceY))
            XCTAssertNil(NotesExchangeCrypto.revealDigest(accountId: accountId, keyA: keyLow, keyB: keyHigh, nonceA: bad, nonceB: nonceY))
            XCTAssertNil(NotesExchangeCrypto.revealDigest(accountId: accountId, keyA: keyLow, keyB: keyHigh, nonceA: nonceX, nonceB: bad))
        }
        for badId in ["", "ABCD123", "ABCD12345", "abcd1234", "ABCD-234", "ABCDI234", "ＡBCD1234", "ABCD1234\u{0}"] {
            XCTAssertNil(NotesExchangeCrypto.revealDigest(accountId: badId, keyA: keyLow, keyB: keyHigh, nonceA: nonceX, nonceB: nonceY), badId)
        }
    }

    func testIdenticalKeysRejected() {
        XCTAssertNil(NotesExchangeCrypto.revealDigest(accountId: accountId, keyA: keyLow, keyB: keyLow, nonceA: nonceX, nonceB: nonceY))
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
