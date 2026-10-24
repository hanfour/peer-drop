import XCTest
import PeerDropNotes
@testable import PeerDrop

@MainActor
final class StrangerBoxTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let bound: Set<String> = ["FRIEND01"]

    private func inbound(_ id: String, _ sender: NoteSenderState, unread: Bool = true) -> NoteRecord {
        NoteRecord(id: id, direction: .inbound, text: "hi", sentAt: t0, sender: sender,
                   recipientAccountId: nil, readAt: unread ? nil : t0, receivedAt: t0)
    }

    private func circle(hide: Bool = false) -> CircleMembership {
        StrangerBox.membership(friendAccounts: bound, diaryMemberLists: [["ME000000", "DIARY001"], ["DIARY001", "DIARY002"]],
                               sent: [], hideAnonymous: hide)
    }

    private var sample: [NoteRecord] {
        [
            inbound("friend", .verified(accountId: "FRIEND01", nickname: "Mochi")),         // bound: lives in the thread
            inbound("diary", .verified(accountId: "DIARY001", nickname: nil)),              // circle, not bound
            inbound("anon1", .anonymous),
            inbound("anon2", .anonymous),
            inbound("signedStranger", .verified(accountId: "STRANGE1", nickname: "Sam")),
            inbound("unver", .unverified(accountId: "FRIEND01")),                           // spoof of a friend id
            inbound("readStranger", .verified(accountId: "STRANGE2", nickname: nil), unread: false),
        ]
    }

    // MARK: partition

    func testPartitionWithHideOff() {
        let p = StrangerBox.partition(sample, boundAccounts: bound, circle: circle())
        XCTAssertEqual(p.circle.map(\.id), ["diary"])
        XCTAssertEqual(p.strangers.map(\.id), ["anon1", "anon2", "signedStranger", "unver", "readStranger"])
        XCTAssertTrue(p.hidden.isEmpty)
    }

    func testBoundFriendNotesStayInTheThreadAndOutOfEveryPartition() {
        let p = StrangerBox.partition(sample, boundAccounts: bound, circle: circle())
        XCTAssertFalse((p.circle + p.strangers + p.hidden).contains { $0.id == "friend" })
        // Same dedupe the existing filter does.
        XCTAssertEqual(Set((p.circle + p.strangers + p.hidden).map(\.id)).union(["friend"]), Set(sample.map(\.id)))
    }

    func testHidingAnonymousMovesOnlyAnonymousNotes() {
        let p = StrangerBox.partition(sample, boundAccounts: bound, circle: circle(hide: true))
        XCTAssertEqual(p.hidden.map(\.id), ["anon1", "anon2"])
        XCTAssertEqual(p.strangers.map(\.id), ["signedStranger", "unver", "readStranger"])
        XCTAssertEqual(p.circle.map(\.id), ["diary"])
    }

    func testHidingDoesNotTouchStorageAndUnhidingBringsThemBack() {
        let store = NotesStore(mockInbox: sample, sent: [])
        let before = store.inbox.map(\.id)
        let hiddenOn = StrangerBox.partition(store.inbox, boundAccounts: bound, circle: circle(hide: true))
        XCTAssertEqual(hiddenOn.hidden.count, 2)
        XCTAssertEqual(store.inbox.map(\.id), before, "hiding is a view over the store, never a deletion")
        let hiddenOff = StrangerBox.partition(store.inbox, boundAccounts: bound, circle: circle(hide: false))
        XCTAssertEqual(hiddenOff.strangers.filter { $0.sender == .anonymous }.count, 2)
    }

    // MARK: unread math

    func testUnreadNumbersKeepStrangerAndFriendCountsApart() {
        let u = StrangerBox.unread(sample, boundAccounts: bound, circle: circle())
        // unread: friend, diary, anon1, anon2, signedStranger, unver = 6 (readStranger is read)
        XCTAssertEqual(u.tabBadge, 6)
        XCTAssertEqual(u.friendRows, 1)
        XCTAssertEqual(u.strangerUnread, 4)
        XCTAssertEqual(u.inboxRemainder, 5)          // diary + 4 strangers
        XCTAssertEqual(u.hiddenUnread, 0)
        XCTAssertEqual(u.tabBadge, u.friendRows + u.inboxRemainder)
    }

    func testHiddenAnonymousLeaveTheStrangerCountAndTheTabBadge() {
        let u = StrangerBox.unread(sample, boundAccounts: bound, circle: circle(hide: true))
        XCTAssertEqual(u.hiddenUnread, 2)
        XCTAssertEqual(u.strangerUnread, 2)          // signedStranger, unver
        XCTAssertEqual(u.tabBadge, 4)                // friend, diary, signedStranger, unver
        XCTAssertEqual(u.friendRows, 1)
        XCTAssertEqual(u.inboxRemainder, 3)
        XCTAssertEqual(u.tabBadge, u.friendRows + u.inboxRemainder)
    }

    func testFriendBadgeIsIndependentOfStrangerNotes() {
        let onlyFriend = [inbound("friend", .verified(accountId: "FRIEND01", nickname: nil))]
        let withStrangers = onlyFriend + [inbound("a", .anonymous), inbound("b", .verified(accountId: "STRANGE1", nickname: nil))]
        let a = StrangerBox.unread(onlyFriend, boundAccounts: bound, circle: circle())
        let b = StrangerBox.unread(withStrangers, boundAccounts: bound, circle: circle())
        XCTAssertEqual(a.friendRows, b.friendRows)
        XCTAssertEqual(b.tabBadge, a.tabBadge + 2)
    }

    func testProjectCUnreadMathIsUnchangedWhenNothingIsHidden() {
        let u = StrangerBox.unread(sample, boundAccounts: bound, circle: circle())
        let c = ConversationsLogic.unread(total: 6, boundUnread: 1)
        XCTAssertEqual(u.tabBadge, c.tabBadge)
        XCTAssertEqual(u.inboxRemainder, c.inboxRemainder)
        XCTAssertEqual(u.friendRows, c.friendRows)
    }

    func testEmptyInbox() {
        XCTAssertEqual(StrangerBox.unread([], boundAccounts: [], circle: CircleMembership()),
                       StrangerBox.Unread(tabBadge: 0, inboxRemainder: 0, friendRows: 0, strangerUnread: 0, hiddenUnread: 0))
    }

    // MARK: membership and local-only reading

    func testMembershipCollectsFriendsDiaryMembersAndSignedRecipients() {
        let sent = [
            NoteRecord(id: "s1", direction: .outbound, text: "a", sentAt: t0, sender: .verified(accountId: "ME000000", nickname: nil), recipientAccountId: "SIGNED01", readAt: nil, receivedAt: t0),
            NoteRecord(id: "s2", direction: .outbound, text: "b", sentAt: t0, sender: .anonymous, recipientAccountId: "ANON0001", readAt: nil, receivedAt: t0),
        ]
        let m = StrangerBox.membership(friendAccounts: ["F1"], diaryMemberLists: [["D1", "D2"], ["D2"]], sent: sent, hideAnonymous: true)
        XCTAssertEqual(m.friendAccountIds, ["F1"])
        XCTAssertEqual(m.diaryMemberAccountIds, ["D1", "D2"])
        XCTAssertEqual(m.sentSignedToAccountIds, ["SIGNED01"])
        XCTAssertTrue(m.hideAnonymous)
    }

    func testReadingIsLocalOnlyForEverythingOutsideTheCircle() {
        let c = circle()
        XCTAssertFalse(StrangerBox.readIsLocalOnly(inbound("d", .verified(accountId: "DIARY001", nickname: nil)), circle: c))
        XCTAssertTrue(StrangerBox.readIsLocalOnly(inbound("a", .anonymous), circle: c))
        XCTAssertTrue(StrangerBox.readIsLocalOnly(inbound("s", .verified(accountId: "STRANGE1", nickname: nil)), circle: c))
        XCTAssertTrue(StrangerBox.readIsLocalOnly(inbound("u", .unverified(accountId: "DIARY001")), circle: c))
    }
}
