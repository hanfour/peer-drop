import XCTest
@testable import PeerDropNotes

@MainActor
final class NoteOutboxFailureTests: XCTestCase {
    func testSenderReasonsMapToCodes() {
        XCTAssertEqual(NoteOutboxFailure(reason: NoteOutboxSender.boundCancelledReason), .bindingCancelled)
        XCTAssertEqual(NoteOutboxFailure(reason: NoteOutboxSender.exhaustedReason(NotesStoreError.inboxFull)), .inboxFull)
        XCTAssertEqual(NoteOutboxFailure(reason: NoteOutboxSender.exhaustedReason(nil)), .exhausted)
        XCTAssertEqual(NoteOutboxFailure(reason: NoteOutboxSender.terminalReason(NotesStoreError.recipientNotFound)), .recipientNotFound)
        XCTAssertEqual(NoteOutboxFailure(reason: NoteOutboxSender.terminalReason(NotesStoreError.recipientHasNoKeys)), .recipientHasNoKeys)
        XCTAssertEqual(NoteOutboxFailure(reason: NoteOutboxSender.terminalReason(NotesStoreError.recipientMismatch)), .recipientChanged)
        XCTAssertEqual(NoteOutboxFailure(reason: NoteOutboxSender.terminalReason(NotesStoreError.textTooLong)), .tooLong)
        XCTAssertEqual(NoteOutboxFailure(reason: NoteOutboxSender.terminalReason(NotesStoreError.noteNotFound)), .noteNotFound)
    }

    func testLiteralReasonsAndUnknown() {
        XCTAssertEqual(NoteOutboxFailure(reason: "超過 24 小時仍未寄出"), .tooOld)
        XCTAssertEqual(NoteOutboxFailure(reason: "已封鎖此聯絡人，未寄出"), .blocked)
        XCTAssertNil(NoteOutboxFailure(reason: "something else"))
        XCTAssertNil(NoteOutboxFailure(reason: nil))
    }
}
