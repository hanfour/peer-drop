import XCTest
import PeerDropCore
@testable import PeerDrop

final class ConnectionErrorPolicyTests: XCTestCase {
    func testDroppedLiveConnectionIsAToastNotAnAlert() {
        for live: ConnectionState in [.connected, .transferring(progress: 0.5), .voiceCall] {
            XCTAssertEqual(ConnectionErrorPolicy.presentation(from: live, to: .failed(reason: "Connection lost"), suppressAlert: false),
                           .toast(ConnectionErrorPolicy.droppedToastKey))
        }
    }

    func testDroppedLiveConnectionStillToastsWhileChatSuppressesAlerts() {
        XCTAssertEqual(ConnectionErrorPolicy.presentation(from: .connected, to: .failed(reason: "x"), suppressAlert: true),
                       .toast(ConnectionErrorPolicy.droppedToastKey))
    }

    func testFailedAttemptShowsTheAlert() {
        for attempt: ConnectionState in [.requesting, .connecting, .peerFound, .discovering] {
            XCTAssertEqual(ConnectionErrorPolicy.presentation(from: attempt, to: .failed(reason: "timed out"), suppressAlert: false),
                           .alert("timed out"))
        }
    }

    func testFailedAttemptIsSilentWhenSuppressed() {
        XCTAssertEqual(ConnectionErrorPolicy.presentation(from: .connecting, to: .failed(reason: "x"), suppressAlert: true), .none)
    }

    func testOtherTransitionsAreNotErrors() {
        XCTAssertEqual(ConnectionErrorPolicy.presentation(from: .connected, to: .disconnected, suppressAlert: false), .none)
        XCTAssertEqual(ConnectionErrorPolicy.presentation(from: .idle, to: .connecting, suppressAlert: false), .none)
    }
}
