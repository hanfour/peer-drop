import XCTest
import CryptoKit
@testable import PeerDrop

final class SessionKeyManagerTests: XCTestCase {

    func testDeriveSessionKey() throws {
        let alice = Curve25519.KeyAgreement.PrivateKey()
        let bob = Curve25519.KeyAgreement.PrivateKey()

        let sessionAlice = try SessionKeyManager.deriveSessionKey(
            myPrivateKey: alice,
            peerPublicKey: bob.publicKey
        )
        let sessionBob = try SessionKeyManager.deriveSessionKey(
            myPrivateKey: bob,
            peerPublicKey: alice.publicKey
        )
        XCTAssertEqual(sessionAlice, sessionBob)
    }

    func testDifferentPeersProduceDifferentKeys() throws {
        let alice = Curve25519.KeyAgreement.PrivateKey()
        let bob = Curve25519.KeyAgreement.PrivateKey()
        let carol = Curve25519.KeyAgreement.PrivateKey()

        let keyAB = try SessionKeyManager.deriveSessionKey(
            myPrivateKey: alice,
            peerPublicKey: bob.publicKey
        )
        let keyAC = try SessionKeyManager.deriveSessionKey(
            myPrivateKey: alice,
            peerPublicKey: carol.publicKey
        )
        XCTAssertNotEqual(keyAB, keyAC)
    }

    func testEncryptDecryptRoundTrip() throws {
        let alice = Curve25519.KeyAgreement.PrivateKey()
        let bob = Curve25519.KeyAgreement.PrivateKey()

        let key = try SessionKeyManager.deriveSessionKey(
            myPrivateKey: alice,
            peerPublicKey: bob.publicKey
        )

        let plaintext = "Hello, secure world!".data(using: .utf8)!
        let encrypted = try SessionKeyManager.encrypt(plaintext, with: key)
        XCTAssertNotEqual(encrypted, plaintext)

        let decrypted = try SessionKeyManager.decrypt(encrypted, with: key)
        XCTAssertEqual(decrypted, plaintext)
    }

    func testDecryptWithWrongKeyFails() throws {
        let alice = Curve25519.KeyAgreement.PrivateKey()
        let bob = Curve25519.KeyAgreement.PrivateKey()
        let carol = Curve25519.KeyAgreement.PrivateKey()

        let keyAB = try SessionKeyManager.deriveSessionKey(
            myPrivateKey: alice,
            peerPublicKey: bob.publicKey
        )
        let keyAC = try SessionKeyManager.deriveSessionKey(
            myPrivateKey: alice,
            peerPublicKey: carol.publicKey
        )

        let plaintext = "secret".data(using: .utf8)!
        let encrypted = try SessionKeyManager.encrypt(plaintext, with: keyAB)

        XCTAssertThrowsError(try SessionKeyManager.decrypt(encrypted, with: keyAC))
    }

    func testEncryptedDataIncludesNonce() throws {
        let alice = Curve25519.KeyAgreement.PrivateKey()
        let bob = Curve25519.KeyAgreement.PrivateKey()
        let key = try SessionKeyManager.deriveSessionKey(
            myPrivateKey: alice,
            peerPublicKey: bob.publicKey
        )

        let plaintext = "same message".data(using: .utf8)!
        let enc1 = try SessionKeyManager.encrypt(plaintext, with: key)
        let enc2 = try SessionKeyManager.encrypt(plaintext, with: key)
        XCTAssertNotEqual(enc1, enc2)
    }

    func testLargeDataEncryption() throws {
        let alice = Curve25519.KeyAgreement.PrivateKey()
        let bob = Curve25519.KeyAgreement.PrivateKey()
        let key = try SessionKeyManager.deriveSessionKey(
            myPrivateKey: alice,
            peerPublicKey: bob.publicKey
        )

        let plaintext = Data(repeating: 0xAB, count: 1_000_000)
        let encrypted = try SessionKeyManager.encrypt(plaintext, with: key)
        let decrypted = try SessionKeyManager.decrypt(encrypted, with: key)
        XCTAssertEqual(decrypted, plaintext)
    }
}
