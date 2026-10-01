import XCTest
import Network
@testable import PeerDropCore
@testable import PeerDropProtocol
@testable import PeerDropSecurity

/// `onTextMessageReceived` is the CLI/headless inbound-text hook. Since #161
/// it fires only from bound dispatch — for a frame that arrived on a
/// consented connection — and reports THAT connection's peer ID, never the
/// frame's self-reported `senderID`. (The pre-consent / stranger cases, where
/// it must not fire at all, are driven over real loopback sockets in
/// PeerDropCoreTests/ConnectionManagerSenderBindingTests.)
final class ConnectionManagerHookTests: XCTestCase {
    @MainActor
    private func installConnection(_ cm: ConnectionManager, peerID: String) {
        let pc = PeerConnection(
            peerID: peerID,
            connection: NWConnection(host: "127.0.0.1", port: 1, using: .tcp),
            peerIdentity: PeerIdentity(id: peerID, displayName: "iPhone", supportsSecureChannel: false),
            localIdentity: cm.localIdentity,
            state: .connected
        )
        cm._setConnectionForTesting(peerID: peerID, pc)
    }

    @MainActor
    func test_onTextMessageReceived_firesWithDecodedText_forBoundConnection() throws {
        let cm = ConnectionManager()
        installConnection(cm, peerID: "peer-123")
        var received: (peerID: String, text: String)?
        cm.onTextMessageReceived = { peerID, text in received = (peerID, text) }

        let payload = TextMessagePayload(text: "hello from phone", senderName: "iPhone")
        let msg = try PeerMessage.textMessage(payload, senderID: "peer-123")

        cm.dispatchTextForTesting(msg, from: "peer-123")

        XCTAssertEqual(received?.peerID, "peer-123")
        XCTAssertEqual(received?.text, "hello from phone")
        cm.chatManager.deleteMessages(forPeer: "peer-123")
    }

    @MainActor
    func test_onTextMessageReceived_reportsBoundPeer_notClaimedSenderID() throws {
        let cm = ConnectionManager()
        installConnection(cm, peerID: "peer-B")
        var received: [String] = []
        cm.onTextMessageReceived = { peerID, _ in received.append(peerID) }

        // B's socket carries a frame claiming to come from C.
        let payload = TextMessagePayload(text: "spoof", senderName: "C")
        let msg = try PeerMessage.textMessage(payload, senderID: "peer-C")

        cm.dispatchTextForTesting(msg, from: "peer-B")

        XCTAssertEqual(received, ["peer-B"])
        cm.chatManager.deleteMessages(forPeer: "peer-B")
    }

    @MainActor
    func test_onTextMessageReceived_doesNotFireForNonTextMessage() throws {
        let cm = ConnectionManager()
        installConnection(cm, peerID: "peer-9")
        var fired = false
        cm.onTextMessageReceived = { _, _ in fired = true }

        // A non-text control message must not trigger the text hook.
        let msg = PeerMessage.disconnect(senderID: "peer-9")
        cm.dispatchTextForTesting(msg, from: "peer-9")

        XCTAssertFalse(fired)
    }
}
