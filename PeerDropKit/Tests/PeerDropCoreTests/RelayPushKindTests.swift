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

    func testClassifiesDiaryTurnEntryJoinReactionAndKeyRequest() {
        XCTAssertEqual(
            RelayPushKind.classify(["type": "diaryTurn", "diaryId": "D1"]),
            .diary(kind: "diaryTurn", diaryId: "D1", seq: nil))
        XCTAssertEqual(
            RelayPushKind.classify(["type": "diaryEntry", "diaryId": "D1", "seq": 7]),
            .diary(kind: "diaryEntry", diaryId: "D1", seq: 7))
        XCTAssertEqual(
            RelayPushKind.classify(["type": "diaryJoin", "diaryId": "D1", "accountId": "ACCT1234"]),
            .diary(kind: "diaryJoin", diaryId: "D1", seq: nil))
        XCTAssertEqual(
            RelayPushKind.classify(["type": "diaryReaction", "diaryId": "D1", "seq": 3]),
            .diary(kind: "diaryReaction", diaryId: "D1", seq: 3))
        XCTAssertEqual(
            RelayPushKind.classify(["type": "diaryKeyRequest", "diaryId": "D1", "accountId": "ACCT1234"]),
            .diary(kind: "diaryKeyRequest", diaryId: "D1", seq: nil))
        // Missing diaryId still classifies as `.diary` (empty id) rather
        // than falling through — `type` alone is authoritative.
        XCTAssertEqual(RelayPushKind.classify(["type": "diaryTurn"]), .diary(kind: "diaryTurn", diaryId: "", seq: nil))
    }

    func testClassifiesDiaryKey() {
        XCTAssertEqual(RelayPushKind.classify(["type": "diaryKey"]), .diaryKey)
        // A diaryKey payload never carries a diaryId of its own (spec §4) —
        // classification doesn't depend on one being present.
        XCTAssertEqual(RelayPushKind.classify(["type": "diaryKey", "unrelated": "x"]), .diaryKey)
    }

    /// Spec §1/§4: diary classification (and note) must win over `roomCode`
    /// even when a payload somehow carries both keys.
    func testDiaryAndDiaryKeyTakePrecedenceOverRoomCode() {
        XCTAssertEqual(
            RelayPushKind.classify(["type": "diaryEntry", "diaryId": "D1", "seq": 2, "roomCode": "ABC123"]),
            .diary(kind: "diaryEntry", diaryId: "D1", seq: 2))
        XCTAssertEqual(
            RelayPushKind.classify(["type": "diaryKey", "roomCode": "ABC123"]),
            .diaryKey)
        XCTAssertEqual(
            RelayPushKind.classify(["type": "note", "inboxItemId": "01A", "roomCode": "ABC123"]),
            .note(inboxItemId: "01A"))
    }
}
