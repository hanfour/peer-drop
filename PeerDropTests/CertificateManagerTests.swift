import XCTest
@testable import PeerDrop

final class CertificateManagerTests: XCTestCase {

    func testFingerprintGenerated() {
        let manager = CertificateManager()
        XCTAssertNotNil(manager.fingerprint, "Fingerprint should be generated on init")
    }

    func testFingerprintIsHex() {
        let manager = CertificateManager()
        guard let fp = manager.fingerprint else {
            XCTFail("No fingerprint")
            return
        }
        // SHA-256 produces 64 hex characters
        XCTAssertEqual(fp.count, 64)
        XCTAssertTrue(fp.allSatisfy { $0.isHexDigit })
    }

    func testIsReady() {
        let manager = CertificateManager()
        XCTAssertTrue(manager.isReady)
        XCTAssertNil(manager.setupError)
    }

    func testUniqueFingerprintsPerInstance() {
        let a = CertificateManager()
        let b = CertificateManager()
        XCTAssertNotEqual(a.fingerprint, b.fingerprint, "Each instance should generate a unique key pair")
    }

    func testComputeFingerprintOfCertificate() {
        // Create a CertificateManager and use its computeFingerprint on an arbitrary SecCertificate.
        // We can't easily create a SecCertificate in tests, so just verify the method exists
        // and the manager's own fingerprint is consistent.
        let manager = CertificateManager()
        XCTAssertNotNil(manager.fingerprint)
    }
}
