import XCTest
@testable import PeerDrop

@MainActor
final class ConnectionManagerTests: XCTestCase {

    func testInitialState() {
        let manager = ConnectionManager()
        XCTAssertEqual(manager.state, .idle)
        XCTAssertTrue(manager.discoveredPeers.isEmpty)
        XCTAssertNil(manager.connectedPeer)
        XCTAssertNil(manager.pendingIncomingRequest)
    }

    func testValidTransition() {
        let manager = ConnectionManager()
        manager.transition(to: .discovering)
        XCTAssertEqual(manager.state, .discovering)
    }

    func testInvalidTransitionIsIgnored() {
        let manager = ConnectionManager()
        // idle → connected is invalid
        manager.transition(to: .connected)
        XCTAssertEqual(manager.state, .idle)
    }

    func testTransitionChain() {
        let manager = ConnectionManager()
        manager.transition(to: .discovering)
        XCTAssertEqual(manager.state, .discovering)

        manager.transition(to: .peerFound)
        XCTAssertEqual(manager.state, .peerFound)

        manager.transition(to: .requesting)
        XCTAssertEqual(manager.state, .requesting)

        manager.transition(to: .connecting)
        XCTAssertEqual(manager.state, .connecting)

        manager.transition(to: .connected)
        XCTAssertEqual(manager.state, .connected)
    }

    func testDisconnectFromConnected() {
        let manager = ConnectionManager()
        manager.transition(to: .discovering)
        manager.transition(to: .peerFound)
        manager.transition(to: .requesting)
        manager.transition(to: .connecting)
        manager.transition(to: .connected)
        manager.transition(to: .disconnected)
        XCTAssertEqual(manager.state, .disconnected)
    }

    func testFailedRecovery() {
        let manager = ConnectionManager()
        manager.transition(to: .discovering)
        manager.transition(to: .peerFound)
        manager.transition(to: .requesting)
        manager.transition(to: .failed(reason: "timeout"))
        XCTAssertEqual(manager.state, .failed(reason: "timeout"))

        manager.transition(to: .discovering)
        XCTAssertEqual(manager.state, .discovering)
    }
}
