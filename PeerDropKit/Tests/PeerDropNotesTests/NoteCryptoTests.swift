import XCTest
import CryptoKit
import PeerDropSecurity
import PeerDropAccount
@testable import PeerDropNotes

final class NoteCryptoTests: XCTestCase {
    func testSignedRoundTripVerifiesSender() throws {
        let r = try RecipientFixture(), s = SenderFixture()
        let env = try NoteCrypto.seal(text: "hello 紙條", recipient: try r.entry(), signer: s.signer)
        XCTAssertEqual(env.spkId, 7); XCTAssertEqual(env.opkId, 41); XCTAssertEqual(env.nonce.count, 12)
        let pt = try NoteCrypto.open(env, recipientAccountId: "TESTRCPT", keys: r.keys())
        XCTAssertEqual(pt.text, "hello 紙條"); XCTAssertEqual(pt.kind, .note)
        XCTAssertEqual(pt.sender?.accountId, "SENDR001"); XCTAssertEqual(pt.sender?.nickname, "alice")
        XCTAssertTrue(NoteCrypto.verifySender(pt, recipientAccountId: "TESTRCPT", directorySigningKey: s.signing.publicKey.rawRepresentation))
        XCTAssertFalse(NoteCrypto.verifySender(pt, recipientAccountId: "TESTRCPT", directorySigningKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation))
        XCTAssertFalse(NoteCrypto.verifySender(pt, recipientAccountId: "OTHERACC", directorySigningKey: s.signing.publicKey.rawRepresentation))
    }
    func testAnonymousRoundTripHasNoSender() throws {
        let r = try RecipientFixture()
        let env = try NoteCrypto.seal(text: "anon", recipient: try r.entry(), signer: nil)
        let pt = try NoteCrypto.open(env, recipientAccountId: "TESTRCPT", keys: r.keys())
        XCTAssertEqual(pt.text, "anon"); XCTAssertNil(pt.sender)
        XCTAssertFalse(NoteCrypto.verifySender(pt, recipientAccountId: "TESTRCPT", directorySigningKey: Data()))
    }
    func testWrongRecipientAADFails() throws {
        let r = try RecipientFixture()
        let env = try NoteCrypto.seal(text: "x", recipient: try r.entry(), signer: nil)
        XCTAssertThrowsError(try NoteCrypto.open(env, recipientAccountId: "SOMEONE1", keys: r.keys())) { XCTAssertEqual($0 as? NoteCryptoError, .decryptionFailed) }
    }
    func testTamperedCiphertextFails() throws {
        let r = try RecipientFixture()
        var env = try NoteCrypto.seal(text: "x", recipient: try r.entry(), signer: nil)
        env.ciphertext[0] ^= 0xFF
        XCTAssertThrowsError(try NoteCrypto.open(env, recipientAccountId: "TESTRCPT", keys: r.keys())) { XCTAssertEqual($0 as? NoteCryptoError, .decryptionFailed) }
    }
    func testTextLimitAndMissingBundle() throws {
        let r = try RecipientFixture()
        XCTAssertThrowsError(try NoteCrypto.seal(text: String(repeating: "字", count: 2_001), recipient: try r.entry(), signer: nil)) { XCTAssertEqual($0 as? NoteCryptoError, .textTooLong) }
        XCTAssertNoThrow(try NoteCrypto.seal(text: String(repeating: "字", count: 2_000), recipient: try r.entry(), signer: nil))
        let noBundle = DirectoryEntry(accountId: r.accountId, nickname: nil, identityKey: Data(count: 32), signingKey: Data(count: 32), mailboxId: "m", preKeyBundle: nil)
        XCTAssertThrowsError(try NoteCrypto.seal(text: "x", recipient: noBundle, signer: nil)) { XCTAssertEqual($0 as? NoteCryptoError, .missingPreKeyBundle) }
    }
    func testBadSignedPreKeySignatureIsRejected() throws {
        let r = try RecipientFixture()
        XCTAssertThrowsError(try NoteCrypto.seal(text: "x", recipient: try r.entry(badSPKSignature: true), signer: nil)) { XCTAssertEqual($0 as? NoteCryptoError, .invalidSignedPreKeySignature) }
    }
    func testOPKExhaustionFollowsPolicy() throws {
        let r = try RecipientFixture()
        // v5.4 bundle without OPK → strict policy → fail closed.
        XCTAssertThrowsError(try NoteCrypto.seal(text: "x", recipient: try r.entry(withOPK: false, v54: true), signer: nil)) { XCTAssertEqual($0 as? NoteCryptoError, .opkExhausted) }
        // Legacy bundle without OPK → proceed without DH4; opens with opkId nil.
        let env = try NoteCrypto.seal(text: "x", recipient: try r.entry(withOPK: false, v54: false), signer: nil)
        XCTAssertNil(env.opkId)
        XCTAssertEqual(try NoteCrypto.open(env, recipientAccountId: "TESTRCPT", keys: r.keys(opkAvailable: false)).text, "x")
    }
    func testOpenFailsWhenKeysAreGone() throws {
        let r = try RecipientFixture()
        let env = try NoteCrypto.seal(text: "x", recipient: try r.entry(), signer: nil)
        XCTAssertThrowsError(try NoteCrypto.open(env, recipientAccountId: "TESTRCPT", keys: r.keys(opkAvailable: false))) { XCTAssertEqual($0 as? NoteCryptoError, .oneTimePreKeyUnavailable) }
        var other = env; other.spkId = 99
        XCTAssertThrowsError(try NoteCrypto.open(other, recipientAccountId: "TESTRCPT", keys: r.keys())) { XCTAssertEqual($0 as? NoteCryptoError, .unknownSignedPreKey) }
        var v2 = env; v2.v = 2
        XCTAssertThrowsError(try NoteCrypto.open(v2, recipientAccountId: "TESTRCPT", keys: r.keys())) { XCTAssertEqual($0 as? NoteCryptoError, .unsupportedVersion) }
    }
    func testTwoSealsUseFreshEphemeralKeys() throws {
        let r = try RecipientFixture()
        let a = try NoteCrypto.seal(text: "x", recipient: try r.entry(), signer: nil)
        let b = try NoteCrypto.seal(text: "x", recipient: try r.entry(), signer: nil)
        XCTAssertNotEqual(a.ephemeralKey, b.ephemeralKey); XCTAssertNotEqual(a.ciphertext, b.ciphertext)
    }
    func testSenderSignatureDigestIsStable() {
        let d = NoteCrypto.senderSignatureDigest(text: "hi", sentAt: 1_700_000_000, recipientAccountId: "TESTRCPT")
        // sha256("peerdrop-note-sender-v1" || "hi" || 0x0000000065 4E 10 00 || "TESTRCPT") — pin once, then keep.
        XCTAssertEqual(d.count, 32)
        XCTAssertEqual(d, NoteCrypto.senderSignatureDigest(text: "hi", sentAt: 1_700_000_000, recipientAccountId: "TESTRCPT"))
        XCTAssertNotEqual(d, NoteCrypto.senderSignatureDigest(text: "hi", sentAt: 1_700_000_001, recipientAccountId: "TESTRCPT"))
    }
}
