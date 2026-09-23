import XCTest
@testable import PeerDropCore

final class RelayPushKindTests: XCTestCase {
    func testClassifiesNoteChatInviteAndOther() {
        XCTAssertEqual(RelayPushKind.classify(["type": "note", "inboxItemId": "01A"]), .note(inboxItemId: "01A"))
        XCTAssertEqual(RelayPushKind.classify(["type": "note"]), .note(inboxItemId: nil))
        XCTAssertEqual(RelayPushKind.classify(["roomCode": "ABC123", "senderName": "x"]), .chatInvite(roomCode: "ABC123"))
        XCTAssertEqual(RelayPushKind.classify(["type": "callRequest"]), .other)
        XCTAssertEqual(RelayPushKind.classify([:]), .other)
    }
}
