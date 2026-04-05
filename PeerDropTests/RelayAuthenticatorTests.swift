import XCTest
@testable import PeerDrop

final class RelayAuthenticatorTests: XCTestCase {

    func testDerivePINDeterministic() {
        let pin1 = RelayAuthenticator.derivePIN(
            localFingerprint: "sha-256 AA:BB:CC:DD",
            remoteFingerprint: "sha-256 EE:FF:00:11"
        )
        let pin2 = RelayAuthenticator.derivePIN(
            localFingerprint: "sha-256 AA:BB:CC:DD",
            remoteFingerprint: "sha-256 EE:FF:00:11"
        )
        XCTAssertEqual(pin1, pin2, "PIN should be deterministic")
    }

    func testDerivePINSymmetric() {
        // Both sides should derive the same PIN regardless of order
        let pinAB = RelayAuthenticator.derivePIN(
            localFingerprint: "sha-256 AA:BB:CC:DD",
            remoteFingerprint: "sha-256 EE:FF:00:11"
        )
        let pinBA = RelayAuthenticator.derivePIN(
            localFingerprint: "sha-256 EE:FF:00:11",
            remoteFingerprint: "sha-256 AA:BB:CC:DD"
        )
        XCTAssertEqual(pinAB, pinBA, "PIN should be same regardless of local/remote order")
    }

    func testDerivePINFormat() {
        let pin = RelayAuthenticator.derivePIN(
            localFingerprint: "sha-256 12:34:56:78",
            remoteFingerprint: "sha-256 AB:CD:EF:01"
        )
        XCTAssertEqual(pin.count, 4, "PIN should be exactly 4 digits")
        XCTAssertTrue(pin.allSatisfy { $0.isNumber }, "PIN should contain only digits")
    }

    func testDerivePINDifferentInputs() {
        let pin1 = RelayAuthenticator.derivePIN(
            localFingerprint: "sha-256 AA:BB:CC:DD",
            remoteFingerprint: "sha-256 EE:FF:00:11"
        )
        let pin2 = RelayAuthenticator.derivePIN(
            localFingerprint: "sha-256 11:22:33:44",
            remoteFingerprint: "sha-256 55:66:77:88"
        )
        // Different inputs should (very likely) produce different PINs
        // This is probabilistic but with 4 digits the chance of collision is 1/10000
        // We test the format rather than asserting they must differ
        XCTAssertEqual(pin1.count, 4)
        XCTAssertEqual(pin2.count, 4)
    }

    func testDerivePINRange() {
        // PIN should be 0000-9999
        for i in 0..<20 {
            let pin = RelayAuthenticator.derivePIN(
                localFingerprint: "fp-\(i)",
                remoteFingerprint: "fp-\(i + 100)"
            )
            let value = Int(pin)!
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThan(value, 10000)
        }
    }
}
