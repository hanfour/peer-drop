import XCTest
@testable import PeerDropCore

/// When a peer drops, ConnectionManager removes its PeerConnection and the
/// global state falls back to `.discovering`, so the chat must treat "no
/// connection for this peer" as disconnected. It used to look only for a
/// `.disconnected/.failed` state, which never exists after removal, so the chat
/// greyed out its input with no explanation.
final class ChatPeerPresenceTests: XCTestCase {
    func test_removedConnection_afterDrop_isDisconnected() {
        XCTAssertTrue(ChatPeerPresence.isDisconnected(connectionState: nil, globalState: .discovering))
        XCTAssertTrue(ChatPeerPresence.isDisconnected(connectionState: nil, globalState: .idle))
    }

    /// Another peer being connected says nothing about this one.
    func test_noConnectionForThisPeer_whileAnotherIsConnected_isDisconnected() {
        XCTAssertTrue(ChatPeerPresence.isDisconnected(connectionState: nil, globalState: .connected))
    }

    /// A dial in progress is not "lost" — don't flash a banner mid-connect.
    func test_noConnectionYet_whileConnecting_isNotDisconnected() {
        XCTAssertFalse(ChatPeerPresence.isDisconnected(connectionState: nil, globalState: .connecting))
        XCTAssertFalse(ChatPeerPresence.isDisconnected(connectionState: nil, globalState: .requesting))
        XCTAssertFalse(ChatPeerPresence.isDisconnected(connectionState: nil, globalState: .incomingRequest))
    }

    func test_liveConnection_perItsOwnState() {
        XCTAssertFalse(ChatPeerPresence.isDisconnected(connectionState: .connected, globalState: .discovering))
        XCTAssertFalse(ChatPeerPresence.isDisconnected(connectionState: .connecting, globalState: .discovering))
        XCTAssertTrue(ChatPeerPresence.isDisconnected(connectionState: .disconnected, globalState: .connected))
        XCTAssertTrue(ChatPeerPresence.isDisconnected(connectionState: .failed(reason: "x"), globalState: .connected))
    }
}
