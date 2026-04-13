import XCTest
import CryptoKit
@testable import PeerDrop

final class PreKeyBundleTests: XCTestCase {

    func testSignedPreKeyGeneration() {
        let signedPreKey = SignedPreKey.generate(
            id: 1,
            signingKey: IdentityKeyManager.shared
        )
        XCTAssertEqual(signedPreKey.id, 1)
        XCTAssertEqual(signedPreKey.publicKey.count, 32)
        XCTAssertFalse(signedPreKey.signature.isEmpty)
    }

    func testSignedPreKeyVerification() {
        let signedPreKey = SignedPreKey.generate(
            id: 1,
            signingKey: IdentityKeyManager.shared
        )
        let isValid = signedPreKey.verify(
            with: IdentityKeyManager.shared.signingPublicKey
        )
        XCTAssertTrue(isValid)
    }

    func testSignedPreKeyRejectsWrongSigner() {
        let signedPreKey = SignedPreKey.generate(
            id: 1,
            signingKey: IdentityKeyManager.shared
        )
        let otherSigningKey = Curve25519.Signing.PrivateKey()
        let isValid = signedPreKey.verify(with: otherSigningKey.publicKey)
        XCTAssertFalse(isValid)
    }

    func testOneTimePreKeyGeneration() {
        let keys = OneTimePreKey.generateBatch(startId: 0, count: 5)
        XCTAssertEqual(keys.count, 5)
        for (i, key) in keys.enumerated() {
            XCTAssertEqual(key.id, UInt32(i))
            XCTAssertEqual(key.publicKey.count, 32)
        }
    }

    func testPreKeyBundleCodable() throws {
        let signedPreKey = SignedPreKey.generate(id: 1, signingKey: IdentityKeyManager.shared)
        let oneTimeKeys = OneTimePreKey.generateBatch(startId: 0, count: 3)

        let bundle = PreKeyBundle(
            identityKey: IdentityKeyManager.shared.publicKey.rawRepresentation,
            signingKey: IdentityKeyManager.shared.signingPublicKey.rawRepresentation,
            signedPreKey: signedPreKey.asPublic(),
            oneTimePreKeys: oneTimeKeys.map { $0.asPublic() }
        )

        let data = try JSONEncoder().encode(bundle)
        let decoded = try JSONDecoder().decode(PreKeyBundle.self, from: data)

        XCTAssertEqual(decoded.identityKey, bundle.identityKey)
        XCTAssertEqual(decoded.signingKey, bundle.signingKey)
        XCTAssertEqual(decoded.signedPreKey.id, bundle.signedPreKey.id)
        XCTAssertEqual(decoded.oneTimePreKeys.count, 3)
    }

    func testPreKeyBundleWithoutOneTimeKeys() throws {
        let signedPreKey = SignedPreKey.generate(id: 1, signingKey: IdentityKeyManager.shared)
        let bundle = PreKeyBundle(
            identityKey: IdentityKeyManager.shared.publicKey.rawRepresentation,
            signingKey: IdentityKeyManager.shared.signingPublicKey.rawRepresentation,
            signedPreKey: signedPreKey.asPublic(),
            oneTimePreKeys: []
        )
        let data = try JSONEncoder().encode(bundle)
        let decoded = try JSONDecoder().decode(PreKeyBundle.self, from: data)
        XCTAssertTrue(decoded.oneTimePreKeys.isEmpty)
    }
}
