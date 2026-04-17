import XCTest
import Combine
@testable import PeerDrop

@MainActor
final class InboxServiceTests: XCTestCase {

    func test_parsesInviteMessage() {
        let service = InboxService(deviceId: "test-id")
        let json = """
        {"type":"relay-invite","roomCode":"ABC123","roomToken":"tok","senderName":"Alice","senderId":"a-id","timestamp":1234}
        """
        let invite = service.parseMessage(json)
        XCTAssertEqual(invite?.roomCode, "ABC123")
        XCTAssertEqual(invite?.roomToken, "tok")
        XCTAssertEqual(invite?.senderName, "Alice")
        XCTAssertEqual(invite?.source, .websocket)
    }

    func test_ignoresNonInviteMessages() {
        let service = InboxService(deviceId: "test-id")
        let invite = service.parseMessage(#"{"type":"ping"}"#)
        XCTAssertNil(invite)
    }

    func test_ignoresMalformedJson() {
        let service = InboxService(deviceId: "test-id")
        XCTAssertNil(service.parseMessage("not json"))
    }
}
