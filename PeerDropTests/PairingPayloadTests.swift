import XCTest
import CryptoKit
@testable import PeerDrop

final class PairingPayloadTests: XCTestCase {

    func testEncodeToURL() {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let payload = PairingPayload(
            publicKey: key.publicKey.rawRepresentation,
            signingPublicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
            fingerprint: "A1B2 C3D4 E5F6 G7H8 I9J0",
            deviceName: "Test iPhone",
            localAddress: "192.168.1.100:8765",
            relayCode: "ABCDEF"
        )

        let url = payload.toURL()
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.scheme, "peerdrop")
        // Verify URL contains expected query parameters
        let urlString = url!.absoluteString
        XCTAssertTrue(urlString.contains("pk="))
        XCTAssertTrue(urlString.contains("spk="))
        XCTAssertTrue(urlString.contains("fp="))
        XCTAssertTrue(urlString.contains("name=Test"))
    }

    func testDecodeFromURL() throws {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let signingKey = Curve25519.Signing.PrivateKey()
        let original = PairingPayload(
            publicKey: key.publicKey.rawRepresentation,
            signingPublicKey: signingKey.publicKey.rawRepresentation,
            fingerprint: "A1B2 C3D4 E5F6 G7H8 I9J0",
            deviceName: "Test iPhone",
            localAddress: "192.168.1.100:8765",
            relayCode: "ABCDEF"
        )

        let url = original.toURL()!
        let decoded = try PairingPayload(from: url)
        XCTAssertEqual(decoded.publicKey, original.publicKey)
        XCTAssertEqual(decoded.signingPublicKey, original.signingPublicKey)
        XCTAssertEqual(decoded.fingerprint, original.fingerprint)
        XCTAssertEqual(decoded.deviceName, original.deviceName)
        XCTAssertEqual(decoded.localAddress, original.localAddress)
        XCTAssertEqual(decoded.relayCode, original.relayCode)
    }

    func testInvalidURLThrows() {
        let url = URL(string: "https://example.com")!
        XCTAssertThrowsError(try PairingPayload(from: url))
    }

    func testSafetyNumberGeneration() {
        let keyA = Curve25519.KeyAgreement.PrivateKey()
        let keyB = Curve25519.KeyAgreement.PrivateKey()

        let num1 = PairingPayload.safetyNumber(
            myPublicKey: keyA.publicKey.rawRepresentation,
            peerPublicKey: keyB.publicKey.rawRepresentation
        )
        let num2 = PairingPayload.safetyNumber(
            myPublicKey: keyB.publicKey.rawRepresentation,
            peerPublicKey: keyA.publicKey.rawRepresentation
        )
        XCTAssertEqual(num1, num2)

        let parts = num1.split(separator: " ")
        XCTAssertEqual(parts.count, 2)
        for part in parts {
            XCTAssertEqual(part.count, 5)
        }
    }
}
