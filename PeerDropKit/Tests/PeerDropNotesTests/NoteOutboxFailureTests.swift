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

    func testEveryCodeRoundTripsThroughItsStoredText() {
        for code in NoteOutboxFailure.allCases {
            XCTAssertEqual(NoteOutboxFailure(reason: code.reasonText), code)
        }
        XCTAssertEqual(Set(NoteOutboxFailure.allCases.map(\.reasonText)).count, NoteOutboxFailure.allCases.count)
    }

    func testUnknownReasonMapsToNil() {
        XCTAssertNil(NoteOutboxFailure(reason: "something else"))
        XCTAssertNil(NoteOutboxFailure(reason: nil))
    }

    func testRetryability() {
        for code in [NoteOutboxFailure.bindingCancelled, .recipientChanged, .blocked, .tooLong, .noteNotFound] {
            XCTAssertFalse(code.isRetryable, "\(code)")
        }
        for code in [NoteOutboxFailure.tooOld, .inboxFull, .exhausted, .recipientNotFound, .recipientHasNoKeys] {
            XCTAssertTrue(code.isRetryable, "\(code)")
        }
    }
}
