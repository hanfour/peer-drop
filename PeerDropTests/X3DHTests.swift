import XCTest
import CryptoKit
@testable import PeerDrop

// Test-only: non-constant-time comparison acceptable for unit tests
extension X3DH.KeyAgreementResult: Equatable {
    public static func == (lhs: X3DH.KeyAgreementResult, rhs: X3DH.KeyAgreementResult) -> Bool {
        lhs.rootKey.withUnsafeBytes { lRoot in
            rhs.rootKey.withUnsafeBytes { rRoot in
                lhs.chainKey.withUnsafeBytes { lChain in
                    rhs.chainKey.withUnsafeBytes { rChain in
                        Data(lRoot) == Data(rRoot) && Data(lChain) == Data(rChain)
                    }
                }
            }
        }
    }
}

final class X3DHTests: XCTestCase {

    func testInitiatorAndResponderDeriveTheSameKey() throws {
        let bobIdentity = Curve25519.KeyAgreement.PrivateKey()
        let bobSignedPreKey = Curve25519.KeyAgreement.PrivateKey()
        let bobOneTimePreKey = Curve25519.KeyAgreement.PrivateKey()

        let aliceIdentity = Curve25519.KeyAgreement.PrivateKey()
        let aliceEphemeral = Curve25519.KeyAgreement.PrivateKey()

        let aliceResult = try X3DH.initiatorKeyAgreement(
            myIdentityKey: aliceIdentity,
            myEphemeralKey: aliceEphemeral,
            theirIdentityKey: bobIdentity.publicKey,
            theirSignedPreKey: bobSignedPreKey.publicKey,
            theirOneTimePreKey: bobOneTimePreKey.publicKey
        )

        let bobResult = try X3DH.responderKeyAgreement(
            myIdentityKey: bobIdentity,
            mySignedPreKey: bobSignedPreKey,
            myOneTimePreKey: bobOneTimePreKey,
            theirIdentityKey: aliceIdentity.publicKey,
            theirEphemeralKey: aliceEphemeral.publicKey
        )

        XCTAssertEqual(aliceResult, bobResult)
    }

    func testX3DHWithoutOneTimePreKey() throws {
        let bobIdentity = Curve25519.KeyAgreement.PrivateKey()
        let bobSignedPreKey = Curve25519.KeyAgreement.PrivateKey()
        let aliceIdentity = Curve25519.KeyAgreement.PrivateKey()
        let aliceEphemeral = Curve25519.KeyAgreement.PrivateKey()

        let aliceResult = try X3DH.initiatorKeyAgreement(
            myIdentityKey: aliceIdentity,
            myEphemeralKey: aliceEphemeral,
            theirIdentityKey: bobIdentity.publicKey,
            theirSignedPreKey: bobSignedPreKey.publicKey,
            theirOneTimePreKey: nil
        )

        let bobResult = try X3DH.responderKeyAgreement(
            myIdentityKey: bobIdentity,
            mySignedPreKey: bobSignedPreKey,
            myOneTimePreKey: nil,
            theirIdentityKey: aliceIdentity.publicKey,
            theirEphemeralKey: aliceEphemeral.publicKey
        )

        XCTAssertEqual(aliceResult, bobResult)
    }

    func testDifferentEphemeralKeysDifferentResults() throws {
        let bobIdentity = Curve25519.KeyAgreement.PrivateKey()
        let bobSignedPreKey = Curve25519.KeyAgreement.PrivateKey()
        let aliceIdentity = Curve25519.KeyAgreement.PrivateKey()

        let result1 = try X3DH.initiatorKeyAgreement(
            myIdentityKey: aliceIdentity,
            myEphemeralKey: Curve25519.KeyAgreement.PrivateKey(),
            theirIdentityKey: bobIdentity.publicKey,
            theirSignedPreKey: bobSignedPreKey.publicKey,
            theirOneTimePreKey: nil
        )
        let result2 = try X3DH.initiatorKeyAgreement(
            myIdentityKey: aliceIdentity,
            myEphemeralKey: Curve25519.KeyAgreement.PrivateKey(),
            theirIdentityKey: bobIdentity.publicKey,
            theirSignedPreKey: bobSignedPreKey.publicKey,
            theirOneTimePreKey: nil
        )

        XCTAssertNotEqual(result1, result2)
    }
}
