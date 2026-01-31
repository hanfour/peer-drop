import XCTest
@testable import PeerDrop

@MainActor
final class ReconnectTests: XCTestCase {

    func testCanReconnectInitiallyFalse() {
        let manager = ConnectionManager()
        XCTAssertFalse(manager.canReconnect)
    }

    func testCanReconnectAfterRequest() {
        let manager = ConnectionManager()
        let peer = MockDiscovery.makePeer(name: "Reconnect Peer")

        // requestConnection sets lastConnectedPeer regardless of state transition success
        manager.transition(to: .discovering)
        manager.requestConnection(to: peer)

        // canReconnect is true because lastConnectedPeer was set
        XCTAssertTrue(manager.canReconnect)
    }

    func testReconnectFromDisconnected() {
        let manager = ConnectionManager()
        let peer = MockDiscovery.makePeer(name: "Disconnect Peer")

        // Walk through valid state transitions to set lastConnectedPeer
        manager.transition(to: .discovering)
        manager.requestConnection(to: peer)
        // requestConnection calls transition(to: .requesting)
        // but discovering → requesting isn't valid, so state stays .discovering.
        // Force a valid path: discovering → peerFound → requesting → failed → discovering
        manager.transition(to: .peerFound)
        manager.transition(to: .requesting)
        manager.transition(to: .failed(reason: "test"))
        manager.transition(to: .discovering)

        // canReconnect should be true because requestConnection set lastConnectedPeer
        XCTAssertTrue(manager.canReconnect)
    }
}
