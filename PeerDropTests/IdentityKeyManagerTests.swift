import XCTest
import CryptoKit
@testable import PeerDrop

final class IdentityKeyManagerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        IdentityKeyManager.shared.deleteIdentity()
    }

    func testGeneratesKeyPairOnFirstAccess() {
        let pubKey = IdentityKeyManager.shared.publicKey
        XCTAssertNotNil(pubKey)
        XCTAssertEqual(pubKey.rawRepresentation.count, 32)
    }

    func testKeyPersistsAcrossInstances() {
        let pubKey1 = IdentityKeyManager.shared.publicKey
        IdentityKeyManager.shared.clearCache()
        let pubKey2 = IdentityKeyManager.shared.publicKey
        XCTAssertEqual(pubKey1.rawRepresentation, pubKey2.rawRepresentation)
    }

    func testFingerprintIsDeterministic() {
        let fp1 = IdentityKeyManager.shared.fingerprint
        let fp2 = IdentityKeyManager.shared.fingerprint
        XCTAssertEqual(fp1, fp2)
        XCTAssertFalse(fp1.isEmpty)
    }

    func testFingerprintFormat() {
        let fp = IdentityKeyManager.shared.fingerprint
        let parts = fp.split(separator: " ")
        XCTAssertEqual(parts.count, 5)
        for part in parts {
            XCTAssertEqual(part.count, 4)
        }
    }

    func testDeleteIdentityRegeneratesNewKey() {
        let pubKey1 = IdentityKeyManager.shared.publicKey
        IdentityKeyManager.shared.deleteIdentity()
        let pubKey2 = IdentityKeyManager.shared.publicKey
        XCTAssertNotEqual(pubKey1.rawRepresentation, pubKey2.rawRepresentation)
    }

    func testSharedSecretDerivation() {
        let otherKey = Curve25519.KeyAgreement.PrivateKey()
        let sharedSecret = try? IdentityKeyManager.shared.deriveSharedSecret(
            with: otherKey.publicKey
        )
        XCTAssertNotNil(sharedSecret)
    }

    func testSignAndVerify() {
        let message = "test message".data(using: .utf8)!
        let signature = try? IdentityKeyManager.shared.sign(message)
        XCTAssertNotNil(signature)

        let pubKey = IdentityKeyManager.shared.signingPublicKey
        let isValid = IdentityKeyManager.shared.verify(
            signature: signature!,
            for: message,
            from: pubKey
        )
        XCTAssertTrue(isValid)
    }

    func testVerifyRejectsWrongMessage() {
        let message = "test message".data(using: .utf8)!
        let wrongMessage = "wrong message".data(using: .utf8)!
        let signature = try! IdentityKeyManager.shared.sign(message)

        let pubKey = IdentityKeyManager.shared.signingPublicKey
        let isValid = IdentityKeyManager.shared.verify(
            signature: signature,
            for: wrongMessage,
            from: pubKey
        )
        XCTAssertFalse(isValid)
    }

    func testPublicKeyExportImport() {
        let pubKey = IdentityKeyManager.shared.publicKey
        let exported = pubKey.rawRepresentation

        let imported = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: exported)
        XCTAssertNotNil(imported)
        XCTAssertEqual(imported?.rawRepresentation, pubKey.rawRepresentation)
    }
}
