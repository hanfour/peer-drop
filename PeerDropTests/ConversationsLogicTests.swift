import XCTest
import PeerDropCore
import PeerDropNotes
@testable import PeerDrop

final class ConversationsLogicTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func rec(_ id: String, _ name: String) -> DeviceRecord {
        DeviceRecord(id: id, displayName: name, sourceType: "bonjour", lastConnected: t0, connectionCount: 1)
    }

    private func summary(_ id: String, group: Bool = false, at offset: TimeInterval?, unread: Int = 0) -> ConversationSummary {
        let msg = offset.map { ChatMessage.text(text: "hi \(id)", isOutgoing: false, peerName: id, timestamp: t0.addingTimeInterval($0)) }
        return ConversationSummary(id: id, isGroup: group, lastMessage: msg, unread: unread)
    }

    private func rows(records: [DeviceRecord], groups: [DeviceGroup] = [],
                      peers: [String: ConversationSummary], groupSummaries: [String: ConversationSummary] = [:],
                      query: String = "") -> [ConversationRowModel] {
        ConversationsLogic.rows(
            records: records, groups: groups,
            summaryForPeer: { peers[$0] ?? self.summary($0, at: nil) },
            summaryForGroup: { groupSummaries[$0] ?? self.summary($0, group: true, at: nil) },
            query: query)
    }

    func testSortedNewestFirst() {
        let r = rows(records: [rec("a", "Amy"), rec("b", "Bob"), rec("c", "Cat")],
                     peers: ["a": summary("a", at: 10), "b": summary("b", at: 30), "c": summary("c", at: 20)])
        XCTAssertEqual(r.map(\.name), ["Bob", "Cat", "Amy"])
    }

    func testRecordsWithoutMessagesAreNotListed() {
        let r = rows(records: [rec("a", "Amy"), rec("b", "Bob")], peers: ["a": summary("a", at: 10)])
        XCTAssertEqual(r.map(\.name), ["Amy"])
    }

    func testOrphanChatFilesAreNotListed() {
        let r = rows(records: [rec("a", "Amy")], peers: ["a": summary("a", at: 10), "ghost": summary("ghost", at: 99)])
        XCTAssertEqual(r.map(\.sourceID), ["a"])
    }

    func testGroupsMixedInAndEmptyGroupsHidden() {
        let g1 = DeviceGroup(id: "g1", name: "Family")
        let g2 = DeviceGroup(id: "g2", name: "Empty")
        let r = rows(records: [rec("a", "Amy"), rec("b", "Bob")], groups: [g1, g2],
                     peers: ["a": summary("a", at: 10), "b": summary("b", at: 30)],
                     groupSummaries: ["g1": summary("g1", group: true, at: 20)])
        XCTAssertEqual(r.map(\.name), ["Bob", "Family", "Amy"])
        XCTAssertEqual(r.map(\.isGroup), [false, true, false])
    }

    func testQueryMatchesNamesOnly() {
        let r = rows(records: [rec("a", "Amy"), rec("b", "Bob")],
                     peers: ["a": summary("a", at: 10), "b": summary("b", at: 30)], query: " AM ")
        XCTAssertEqual(r.map(\.name), ["Amy"])
        // message text is "hi a"/"hi b": must not match
        XCTAssertTrue(rows(records: [rec("a", "Amy")], peers: ["a": summary("a", at: 10)], query: "hi").isEmpty)
    }

    func testSameNameTwoPeopleGetTwoRows() {
        let r = rows(records: [rec("a", "Sam"), rec("b", "Sam")],
                     peers: ["a": summary("a", at: 10), "b": summary("b", at: 20)])
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(Set(r.map(\.id)).count, 2)
        XCTAssertEqual(r.map(\.sourceID), ["b", "a"])
    }

    func testMergedRecordWithNewIDDoesNotLeaveGhostRow() {
        // The old id still has a chat file, but the store now only knows the new id (which has none).
        let r = rows(records: [rec("new", "Amy")], peers: ["old": summary("old", at: 10)])
        XCTAssertTrue(r.isEmpty)
    }

    func testPeerAndGroupWithSameRawIDHaveDistinctRowIDs() {
        let r = rows(records: [rec("x", "Amy")], groups: [DeviceGroup(id: "x", name: "Grp")],
                     peers: ["x": summary("x", at: 10)], groupSummaries: ["x": summary("x", group: true, at: 20)])
        XCTAssertEqual(Set(r.map(\.id)).count, 2)
    }

    func testRowsUseResolvedName() {
        let r = ConversationsLogic.rows(
            records: [rec("a", "relay-ab12")], groups: [],
            summaryForPeer: { self.summary($0, at: 10) }, summaryForGroup: { self.summary($0, group: true, at: nil) },
            query: "amy", name: { _ in "Amy" })
        XCTAssertEqual(r.map(\.name), ["Amy"])
    }

    private func noteSummary(_ id: String, at offset: TimeInterval?, messageAt: TimeInterval? = nil) -> ConversationSummary {
        let note = offset.map {
            NoteRecord(id: "n-\(id)", direction: .inbound, text: "hey", sentAt: t0, sender: .anonymous,
                       recipientAccountId: nil, readAt: nil, receivedAt: t0.addingTimeInterval($0))
        }
        let msg = messageAt.map { ChatMessage.text(text: "hi", isOutgoing: false, peerName: id, timestamp: t0.addingTimeInterval($0)) }
        return ConversationSummary(id: id, isGroup: false, lastMessage: msg, lastNote: note, unread: 0)
    }

    func testNotesOnlyFriendIsListed() {
        let r = rows(records: [rec("a", "Amy")], peers: ["a": noteSummary("a", at: 10)])
        XCTAssertEqual(r.map(\.name), ["Amy"])
    }

    func testFriendWithNeitherMessageNorNoteIsHidden() {
        XCTAssertTrue(rows(records: [rec("a", "Amy")], peers: ["a": noteSummary("a", at: nil)]).isEmpty)
    }

    func testNotesAndMessagesOrderedByNewestActivity() {
        let r = rows(records: [rec("a", "Amy"), rec("b", "Bob"), rec("c", "Cat")],
                     peers: ["a": noteSummary("a", at: 50, messageAt: 10),   // note newest: 50
                             "b": summary("b", at: 30),
                             "c": noteSummary("c", at: 5, messageAt: 40)])    // message newest: 40
        XCTAssertEqual(r.map(\.name), ["Amy", "Cat", "Bob"])
    }

    func testQueryStillFiltersNotesOnlyFriends() {
        let peers = ["a": noteSummary("a", at: 10), "b": noteSummary("b", at: 20)]
        XCTAssertEqual(rows(records: [rec("a", "Amy"), rec("b", "Bob")], peers: peers, query: "bo").map(\.name), ["Bob"])
    }
}

final class ConversationsBadgeMathTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func note(_ id: String, at off: TimeInterval, dir: NoteDirection = .inbound, text: String? = "hey",
                      unread: Bool = false) -> NoteRecord {
        NoteRecord(id: id, direction: dir, text: text, sentAt: t0.addingTimeInterval(off), sender: .anonymous,
                   recipientAccountId: nil, readAt: unread ? nil : t0, receivedAt: t0.addingTimeInterval(off))
    }

    func testThreeUnreadNumbersAreDistinct() {
        // 7 unread notes overall; 4 belong to bound friends.
        let u = ConversationsLogic.unread(total: 7, boundUnread: 4)
        XCTAssertEqual(u.tabBadge, 7)          // TOTAL: bound-friend notes must still raise the tab badge
        XCTAssertEqual(u.inboxRemainder, 3)    // inbox row only
        XCTAssertEqual(u.friendRows, 4)        // sum shown on friend rows
        XCTAssertEqual(ConversationsLogic.unread(total: 1, boundUnread: 4).inboxRemainder, 0)
    }

    func testOutboundNotePreviewHasYouPrefixAndEqualTimestampPrefersNote() {
        let msg = ChatMessage.text(text: "chat", isOutgoing: false, peerName: "p", timestamp: t0.addingTimeInterval(10))
        let out = NoteRecord(id: "o", direction: .outbound, text: "mail", sentAt: t0.addingTimeInterval(10), sender: .anonymous,
                             recipientAccountId: "B", readAt: nil, receivedAt: t0)
        let tie = ConversationSummary(id: "p", isGroup: false, lastMessage: msg, lastNote: out, unread: 0)
        XCTAssertEqual(ConversationsLogic.preview(tie), String(format: String(localized: "You: %@"), "📮 mail"))
        let older = NoteRecord(id: "o2", direction: .inbound, text: "mail", sentAt: t0, sender: .anonymous,
                               recipientAccountId: nil, readAt: nil, receivedAt: t0.addingTimeInterval(9))
        let msgNewer = ConversationSummary(id: "p", isGroup: false, lastMessage: msg, lastNote: older, unread: 0)
        XCTAssertEqual(ConversationsLogic.preview(msgNewer), "chat")
    }

    func testFoldPeersFoldsEachAccountIntoExactlyOneRow() {
        let n = NoteRecord(id: "n", direction: .inbound, text: "x", sentAt: t0, sender: .verified(accountId: "ACCT", nickname: nil),
                           recipientAccountId: nil, readAt: nil, receivedAt: t0.addingTimeInterval(5))
        let out = ConversationsLogic.foldPeers(
            recordIDs: ["r1", "r2", "r3"], chatKey: { $0 },
            base: { ConversationSummary(id: $0, isGroup: false, lastMessage: nil, unread: 1) },
            accountForRecord: ["r1": "ACCT"],            // r2 resolved to the same account but lost the tie
            notes: { $0 == "ACCT" ? [n] : [] }, noteUnread: { $0 == "ACCT" ? 2 : 0 })
        XCTAssertEqual(out["r1"]?.lastNote?.id, "n")
        XCTAssertEqual(out["r1"]?.unread, 3)
        XCTAssertNil(out["r2"]?.lastNote)
        XCTAssertEqual(out["r2"]?.unread, 1)
        XCTAssertEqual(out["r3"]?.unread, 1)
    }

    func testInboxUnreadSubtractsBoundAndNeverNegative() {
        XCTAssertEqual(ConversationsLogic.inboxUnread(total: 5, boundUnread: 2), 3)
        XCTAssertEqual(ConversationsLogic.inboxUnread(total: 2, boundUnread: 2), 0)
        XCTAssertEqual(ConversationsLogic.inboxUnread(total: 1, boundUnread: 4), 0)
        XCTAssertEqual(ConversationsLogic.inboxUnread(total: 0, boundUnread: 0), 0)
    }

    func testFoldAddsNewestNoteAndUnread() {
        let base = ConversationSummary(id: "p", isGroup: false, lastMessage: nil, unread: 2)
        let s = ConversationsLogic.fold(base, notes: [note("old", at: 5), note("new", at: 50), note("mid", at: 20)], noteUnread: 3)
        XCTAssertEqual(s.lastNote?.id, "new")
        XCTAssertEqual(s.unread, 5)
        XCTAssertEqual(s.lastActivity, t0.addingTimeInterval(50))
    }

    func testFoldUsesThreadDateForNewestAndTiesById() {
        // Outbound uses sentAt, inbound receivedAt.
        let out = NoteRecord(id: "o", direction: .outbound, text: "x", sentAt: t0.addingTimeInterval(90), sender: .anonymous,
                             recipientAccountId: "B", readAt: nil, receivedAt: t0)
        let s = ConversationsLogic.fold(ConversationSummary(id: "p", isGroup: false, lastMessage: nil, unread: 0),
                                        notes: [note("i", at: 40), out], noteUnread: 0)
        XCTAssertEqual(s.lastNote?.id, "o")
    }

    func testFoldWithNoNotesIsIdentity() {
        let base = ConversationSummary(id: "p", isGroup: false, lastMessage: nil, unread: 2)
        XCTAssertEqual(ConversationsLogic.fold(base, notes: [], noteUnread: 0), base)
    }

    func testNotePreviewUsesMailboxPrefixAndFallbackWhenUndecryptable() {
        XCTAssertEqual(ConversationsLogic.notePreview(note("a", at: 1, text: "hello")), "📮 hello")
        let fb = ConversationsLogic.notePreview(note("b", at: 1, text: nil))
        XCTAssertTrue(fb.hasPrefix("📮 "))
        XCTAssertGreaterThan(fb.count, 3)
    }

    func testBoundUnreadCountedOnceOverall() {
        // total 4 unread; friend rows hold 3 of them -> inbox shows 1; rows (3) + inbox (1) == total.
        let total = 4, bound = 3
        XCTAssertEqual(ConversationsLogic.inboxUnread(total: total, boundUnread: bound) + bound, total)
    }
}
