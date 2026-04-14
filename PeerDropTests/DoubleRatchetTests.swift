import XCTest
import CryptoKit
@testable import PeerDrop

final class DoubleRatchetTests: XCTestCase {

    private func createSessionPair() throws -> (alice: DoubleRatchetSession, bob: DoubleRatchetSession) {
        let aliceIdentity = Curve25519.KeyAgreement.PrivateKey()
        let aliceEphemeral = Curve25519.KeyAgreement.PrivateKey()
        let bobIdentity = Curve25519.KeyAgreement.PrivateKey()
        let bobSignedPreKey = Curve25519.KeyAgreement.PrivateKey()

        let aliceX3DH = try X3DH.initiatorKeyAgreement(
            myIdentityKey: aliceIdentity,
            myEphemeralKey: aliceEphemeral,
            theirIdentityKey: bobIdentity.publicKey,
            theirSignedPreKey: bobSignedPreKey.publicKey,
            theirOneTimePreKey: nil
        )
        let bobX3DH = try X3DH.responderKeyAgreement(
            myIdentityKey: bobIdentity,
            mySignedPreKey: bobSignedPreKey,
            myOneTimePreKey: nil,
            theirIdentityKey: aliceIdentity.publicKey,
            theirEphemeralKey: aliceEphemeral.publicKey
        )

        let alice = DoubleRatchetSession.initializeAsInitiator(
            rootKey: aliceX3DH.rootKey,
            theirRatchetKey: bobSignedPreKey.publicKey
        )
        let bob = DoubleRatchetSession.initializeAsResponder(
            rootKey: bobX3DH.rootKey,
            myRatchetKey: bobSignedPreKey
        )
        return (alice, bob)
    }

    func testSingleMessageEncryptDecrypt() throws {
        let (alice, bob) = try createSessionPair()
        let plaintext = "Hello Bob!".data(using: .utf8)!

        let encrypted = try alice.encrypt(plaintext)
        let decrypted = try bob.decrypt(encrypted)

        XCTAssertEqual(decrypted, plaintext)
    }

    func testMultipleMessagesOneDirection() throws {
        let (alice, bob) = try createSessionPair()

        for i in 0..<5 {
            let msg = "Message \(i)".data(using: .utf8)!
            let encrypted = try alice.encrypt(msg)
            let decrypted = try bob.decrypt(encrypted)
            XCTAssertEqual(decrypted, msg)
        }
    }

    func testBidirectionalMessages() throws {
        let (alice, bob) = try createSessionPair()

        let m1 = try alice.encrypt("Alice to Bob 1".data(using: .utf8)!)
        XCTAssertEqual(try bob.decrypt(m1), "Alice to Bob 1".data(using: .utf8)!)

        let m2 = try bob.encrypt("Bob to Alice 1".data(using: .utf8)!)
        XCTAssertEqual(try alice.decrypt(m2), "Bob to Alice 1".data(using: .utf8)!)

        let m3 = try alice.encrypt("Alice to Bob 2".data(using: .utf8)!)
        XCTAssertEqual(try bob.decrypt(m3), "Alice to Bob 2".data(using: .utf8)!)
    }

    func testOutOfOrderMessages() throws {
        let (alice, bob) = try createSessionPair()

        let m1 = try alice.encrypt("First".data(using: .utf8)!)
        let m2 = try alice.encrypt("Second".data(using: .utf8)!)
        let m3 = try alice.encrypt("Third".data(using: .utf8)!)

        // Deliver out of order
        XCTAssertEqual(try bob.decrypt(m3), "Third".data(using: .utf8)!)
        XCTAssertEqual(try bob.decrypt(m1), "First".data(using: .utf8)!)
        XCTAssertEqual(try bob.decrypt(m2), "Second".data(using: .utf8)!)
    }

    func testReplayProtection() throws {
        let (alice, bob) = try createSessionPair()

        let encrypted = try alice.encrypt("Hello".data(using: .utf8)!)
        _ = try bob.decrypt(encrypted)

        XCTAssertThrowsError(try bob.decrypt(encrypted))
    }

    func testForwardSecrecy() throws {
        let (alice, bob) = try createSessionPair()

        let m1 = try alice.encrypt("Secret 1".data(using: .utf8)!)
        _ = try bob.decrypt(m1)

        for i in 0..<10 {
            let msg = try alice.encrypt("msg \(i)".data(using: .utf8)!)
            _ = try bob.decrypt(msg)
        }

        XCTAssertThrowsError(try bob.decrypt(m1))
    }

    func testEachMessageHasUniqueKey() throws {
        let (alice, _) = try createSessionPair()

        let e1 = try alice.encrypt("Same message".data(using: .utf8)!)
        let e2 = try alice.encrypt("Same message".data(using: .utf8)!)

        XCTAssertNotEqual(e1.ciphertext, e2.ciphertext)
    }
}
