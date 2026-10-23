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

    func testSentUnbindSequenceRestoresInboxAndSent() {
        let inb = [inbound("a", .verified(accountId: "BOUND123", nickname: nil))]
        let out = [outbound("s", to: "BOUND123", sender: .verified(accountId: "ME", nickname: nil))]
        XCTAssertTrue(NotesInboxFilter.inbox(inb, boundAccounts: bound).isEmpty)
        XCTAssertTrue(NotesInboxFilter.sent(out, boundAccounts: bound).isEmpty)
        XCTAssertEqual(NotesInboxFilter.inbox(inb, boundAccounts: []).map(\.id), ["a"])
        XCTAssertEqual(NotesInboxFilter.sent(out, boundAccounts: []).map(\.id), ["s"])
    }

    /// Real NotesStore: the filter's thread membership must equal `notes(forAccount:)`, and the bound
    /// unread ids must equal the sum of per-friend unread counts (no double counting).
    @MainActor
    func testFilterMatchesRealNotesStoreMembershipAndUnreadSums() {
        let v1: NoteSenderState = .verified(accountId: "FRIENDA1", nickname: nil)
        let v2: NoteSenderState = .verified(accountId: "FRIENDB2", nickname: nil)
        let me: NoteSenderState = .verified(accountId: "MYSELF99", nickname: nil)
        let inboxNotes = [
            inbound("i1", v1), inbound("i2", v1), inbound("i3", v2),
            inbound("i4", .unverified(accountId: "FRIENDA1")), inbound("i5", .anonymous),
            inbound("i6", .verified(accountId: "STRANGE7", nickname: nil)),
        ]
        let sentNotes = [outbound("s1", to: "FRIENDA1", sender: me), outbound("s2", to: "FRIENDA1", sender: .anonymous),
                         outbound("s3", to: "FRIENDB2", sender: me), outbound("s4", to: "STRANGE7", sender: me)]
        let store = NotesStore(mockInbox: inboxNotes, sent: sentNotes)
        let accounts: Set<String> = ["FRIENDA1", "FRIENDB2"]

        for account in accounts {
            let threadIDs = Set(store.notes(forAccount: account).map(\.id))
            let filterIDs = Set((store.inbox + store.sent).filter {
                NotesInboxFilter.isInThread($0, boundAccounts: [account])
            }.map(\.id))
            XCTAssertEqual(threadIDs, filterIDs, account)
        }
        // inbox + sent shown = everything not in a thread
        let hidden = Set((store.inbox + store.sent).map(\.id)).subtracting(
            (NotesInboxFilter.inbox(store.inbox, boundAccounts: accounts) + NotesInboxFilter.sent(store.sent, boundAccounts: accounts)).map(\.id))
        XCTAssertEqual(hidden, Set(accounts.flatMap { store.notes(forAccount: $0).map(\.id) }))

        let perFriend = accounts.map { store.unreadCount(forAccount: $0) }.reduce(0, +)
        XCTAssertEqual(store.boundUnreadIDs(accounts: accounts).count, perFriend)
        XCTAssertEqual(perFriend, 3)
        // total = per-friend rows + inbox remainder (each unread note counted once)
        let u = ConversationsLogic.unread(total: store.unreadCount, boundUnread: store.boundUnreadIDs(accounts: accounts).count)
        XCTAssertEqual(u.friendRows + u.inboxRemainder, u.tabBadge)
        XCTAssertEqual(u.tabBadge, 6)
        XCTAssertEqual(u.inboxRemainder, 3)
    }
}
