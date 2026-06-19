import XCTest
@testable import PeerDropCore
@testable import PeerDropProtocol

final class ConnectionManagerHookTests: XCTestCase {
    @MainActor
    func test_onTextMessageReceived_firesWithDecodedText() throws {
        let cm = ConnectionManager()
        var received: (peerID: String, text: String)?
        cm.onTextMessageReceived = { peerID, text in received = (peerID, text) }

        let payload = TextMessagePayload(
            text: "hello from phone",
            senderName: "iPhone"
        )
        let msg = try PeerMessage.textMessage(payload, senderID: "peer-123")

        cm.dispatchTextForTesting(msg, from: "peer-123")

        XCTAssertEqual(received?.peerID, "peer-123")
        XCTAssertEqual(received?.text, "hello from phone")
    }

    @MainActor
    func test_onTextMessageReceived_doesNotFireForNonTextMessage() throws {
        let cm = ConnectionManager()
        var fired = false
        cm.onTextMessageReceived = { _, _ in fired = true }

        // A non-text control message must not trigger the text hook.
        let msg = PeerMessage.disconnect(senderID: "peer-9")
        cm.dispatchTextForTesting(msg, from: "peer-9")

        XCTAssertFalse(fired)
    }
}
