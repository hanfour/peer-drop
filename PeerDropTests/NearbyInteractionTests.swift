import XCTest
import NearbyInteraction
@testable import PeerDrop

final class NearbyInteractionTests: XCTestCase {

    // MARK: - Support Check

    func testNISessionIsSupportedCheck() {
        // Just verify the static property is accessible (value depends on device)
        let _ = NearbyInteractionManager.isSupported
    }

    // MARK: - Session Lifecycle

    func testNIManagerCreation() {
        let manager = NearbyInteractionManager()
        XCTAssertTrue(manager.peerProximity.isEmpty)
    }

    func testStopAllSessionsClearsProximity() {
        let manager = NearbyInteractionManager()
        manager.stopAllSessions()
        XCTAssertTrue(manager.peerProximity.isEmpty)
    }

    func testStopSessionForUnknownPeer() {
        let manager = NearbyInteractionManager()
        // Should not crash when stopping a session that doesn't exist
        manager.stopSession(for: "unknown-peer-id")
        XCTAssertTrue(manager.peerProximity.isEmpty)
    }

    // MARK: - ProximityInfo

    func testProximityInfoCreation() {
        let info = NearbyInteractionManager.ProximityInfo(
            distance: 2.5,
            direction: SIMD3<Float>(1, 0, 0)
        )
        XCTAssertEqual(info.distance, 2.5)
        XCTAssertEqual(info.direction, SIMD3<Float>(1, 0, 0))
    }

    func testProximityInfoNilValues() {
        let info = NearbyInteractionManager.ProximityInfo(
            distance: nil,
            direction: nil
        )
        XCTAssertNil(info.distance)
        XCTAssertNil(info.direction)
    }

    // MARK: - Token Handling Edge Cases

    func testHandleTokenResponseWithNoSession() {
        let manager = NearbyInteractionManager()
        // Should not crash when handling a token response with no existing session
        let fakeData = Data([0x01, 0x02, 0x03])
        manager.handleTokenResponse(fakeData, from: "unknown-peer")
        // No crash = pass
    }

    func testStartSessionOnUnsupportedDevice() {
        // On simulator, NISession.isSupported is false
        guard !NearbyInteractionManager.isSupported else {
            // Skip on real devices that support NI
            return
        }

        let manager = NearbyInteractionManager()
        var tokenSent = false
        manager.startSession(for: "test-peer") { _ in
            tokenSent = true
        }
        // Token should NOT be sent on unsupported devices
        XCTAssertFalse(tokenSent)
        XCTAssertTrue(manager.peerProximity.isEmpty)
    }
}
