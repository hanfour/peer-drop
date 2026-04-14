import XCTest
import CryptoKit
@testable import PeerDrop

final class DoubleRatchetPersistenceTests: XCTestCase {

    private func createSessionPair() throws -> (alice: DoubleRatchetSession, bob: DoubleRatchetSession) {
        let aliceIdentity = Curve25519.KeyAgreement.PrivateKey()
        let aliceEphemeral = Curve25519.KeyAgreement.PrivateKey()
        let bobIdentity = Curve25519.KeyAgreement.PrivateKey()
        let bobSignedPreKey = Curve25519.KeyAgreement.PrivateKey()

        let aliceX3DH = try X3DH.initiatorKeyAgreement(
            myIdentityKey: aliceIdentity, myEphemeralKey: aliceEphemeral,
            theirIdentityKey: bobIdentity.publicKey, theirSignedPreKey: bobSignedPreKey.publicKey,
            theirOneTimePreKey: nil
        )
        let bobX3DH = try X3DH.responderKeyAgreement(
            myIdentityKey: bobIdentity, mySignedPreKey: bobSignedPreKey,
            myOneTimePreKey: nil, theirIdentityKey: aliceIdentity.publicKey,
            theirEphemeralKey: aliceEphemeral.publicKey
        )

        let alice = DoubleRatchetSession.initializeAsInitiator(
            rootKey: aliceX3DH.rootKey, theirRatchetKey: bobSignedPreKey.publicKey
        )
        let bob = DoubleRatchetSession.initializeAsResponder(
            rootKey: bobX3DH.rootKey, myRatchetKey: bobSignedPreKey
        )
        return (alice, bob)
    }

    func testSerializeAndResumeSession() throws {
        let (alice, bob) = try createSessionPair()

        // Exchange messages to advance ratchet state
        let m1 = try alice.encrypt("Hello".data(using: .utf8)!)
        _ = try bob.decrypt(m1)
        let m2 = try bob.encrypt("Hi back".data(using: .utf8)!)
        _ = try alice.decrypt(m2)

        // Serialize both
        let aliceData = try JSONEncoder().encode(alice)
        let restoredAlice = try JSONDecoder().decode(DoubleRatchetSession.self, from: aliceData)
        let bobData = try JSONEncoder().encode(bob)
        let restoredBob = try JSONDecoder().decode(DoubleRatchetSession.self, from: bobData)

        // Restored sessions should still work
        let m3 = try restoredAlice.encrypt("After restore".data(using: .utf8)!)
        let decrypted = try restoredBob.decrypt(m3)
        XCTAssertEqual(String(data: decrypted, encoding: .utf8), "After restore")

        let m4 = try restoredBob.encrypt("Bob after restore".data(using: .utf8)!)
        let decrypted2 = try restoredAlice.decrypt(m4)
        XCTAssertEqual(String(data: decrypted2, encoding: .utf8), "Bob after restore")
    }

    func testSerializePreservesSkippedKeys() throws {
        let (alice, bob) = try createSessionPair()

        let m1 = try alice.encrypt("First".data(using: .utf8)!)
        let m2 = try alice.encrypt("Second".data(using: .utf8)!)
        let m3 = try alice.encrypt("Third".data(using: .utf8)!)

        // Bob receives m3 first (skips m1, m2)
        _ = try bob.decrypt(m3)

        // Serialize Bob with skipped keys
        let bobData = try JSONEncoder().encode(bob)
        let restoredBob = try JSONDecoder().decode(DoubleRatchetSession.self, from: bobData)

        // Restored Bob should still decrypt skipped messages
        XCTAssertEqual(try restoredBob.decrypt(m1), "First".data(using: .utf8)!)
        XCTAssertEqual(try restoredBob.decrypt(m2), "Second".data(using: .utf8)!)
    }
}
