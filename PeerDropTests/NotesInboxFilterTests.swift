import XCTest
import PeerDropNotes
@testable import PeerDrop

final class NotesInboxFilterTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let bound: Set<String> = ["BOUND123"]

    private func inbound(_ id: String, _ sender: NoteSenderState, text: String? = "hi") -> NoteRecord {
        NoteRecord(id: id, direction: .inbound, text: text, sentAt: t0, sender: sender,
                   recipientAccountId: nil, readAt: nil, receivedAt: t0)
    }

    private func outbound(_ id: String, to: String?, sender: NoteSenderState) -> NoteRecord {
        NoteRecord(id: id, direction: .outbound, text: "yo", sentAt: t0, sender: sender,
                   recipientAccountId: to, readAt: nil, receivedAt: t0)
    }

    func testVerifiedBoundInboundIsHidden() {
        let notes = [inbound("a", .verified(accountId: "BOUND123", nickname: nil))]
        XCTAssertTrue(NotesInboxFilter.inbox(notes, boundAccounts: bound).isEmpty)
    }

    func testAnonymousUnverifiedUnboundAndUndecryptableStayInInbox() {
        let notes = [
            inbound("anon", .anonymous),
            inbound("unver", .unverified(accountId: "BOUND123")),            // claims bound id but unverified
            inbound("other", .verified(accountId: "OTHER456", nickname: nil)),
            inbound("undec", .unverified(accountId: "ZZZ"), text: nil),
        ]
        XCTAssertEqual(NotesInboxFilter.inbox(notes, boundAccounts: bound).map(\.id), ["anon", "unver", "other", "undec"])
    }

    func testOutboundToBoundNonAnonymousIsHiddenFromSent() {
        let notes = [
            outbound("s1", to: "BOUND123", sender: .verified(accountId: "ME", nickname: nil)),
            outbound("s2", to: "BOUND123", sender: .anonymous),                  // anonymous stays
            outbound("s3", to: "OTHER456", sender: .verified(accountId: "ME", nickname: nil)),
            outbound("s4", to: nil, sender: .verified(accountId: "ME", nickname: nil)),
        ]
        XCTAssertEqual(NotesInboxFilter.sent(notes, boundAccounts: bound).map(\.id), ["s2", "s3", "s4"])
    }

    func testUnbindingBringsNotesBack() {
        let notes = [inbound("a", .verified(accountId: "BOUND123", nickname: nil))]
        XCTAssertEqual(NotesInboxFilter.inbox(notes, boundAccounts: bound).count, 0)
        XCTAssertEqual(NotesInboxFilter.inbox(notes, boundAccounts: []).count, 1)
    }

    func testFilterAgreesWithNotesStoreThreadMembership() {
        // Every note the filter hides must be one the thread would show, and vice versa.
        let v = inbound("a", .verified(accountId: "BOUND123", nickname: nil))
        XCTAssertTrue(NotesInboxFilter.isInThread(v, boundAccounts: bound))
        XCTAssertFalse(NotesInboxFilter.isInThread(inbound("b", .unverified(accountId: "BOUND123")), boundAccounts: bound))
    }
}
