import XCTest
@testable import PeerDropCore
import PeerDropNotes

final class ThreadItemTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }

    private func chat(_ id: String, _ off: TimeInterval, out: Bool = false, sender: String? = nil) -> ChatMessage {
        var m = ChatMessage.text(text: id, isOutgoing: out, peerName: "p", timestamp: t0.addingTimeInterval(off))
        m = ChatMessage(id: id, text: m.text, isMedia: false, mediaType: nil, fileName: nil, fileSize: nil, mimeType: nil,
                        duration: nil, thumbnailData: nil, localFileURL: nil, isOutgoing: out, peerName: "p",
                        status: m.status, timestamp: t0.addingTimeInterval(off), senderID: sender)
        return m
    }
    private func note(_ id: String, _ dir: NoteDirection, sent: TimeInterval, received: TimeInterval) -> NoteRecord {
        NoteRecord(id: id, direction: dir, text: "n", sentAt: t0.addingTimeInterval(sent), sender: .anonymous,
                   recipientAccountId: nil, readAt: nil, receivedAt: t0.addingTimeInterval(received))
    }
    private func queued(_ off: TimeInterval) -> NoteOutboxEntry {
        NoteOutboxEntry(contactID: UUID(), accountId: "a", expectedIdentityKey: Data(), text: "q", createdAt: t0.addingTimeInterval(off))
    }
    private func ids(_ items: [ThreadItem]) -> [String] { items.map(\.id) }

    func testIdsDatesAndDirection() {
        let q = queued(5)
        XCTAssertEqual(ThreadItem.chat(chat("c", 1)).id, "chat:c")
        XCTAssertEqual(ThreadItem.note(note("n", .inbound, sent: 0, received: 9)).id, "note:n")
        XCTAssertEqual(ThreadItem.queued(q).id, "queued:\(q.id.uuidString)")
        XCTAssertEqual(ThreadItem.note(note("n", .inbound, sent: 0, received: 9)).date, t0.addingTimeInterval(9))
        XCTAssertEqual(ThreadItem.note(note("n", .outbound, sent: 3, received: 9)).date, t0.addingTimeInterval(3))
        XCTAssertEqual(ThreadItem.queued(q).date, t0.addingTimeInterval(5))
        XCTAssertTrue(ThreadItem.queued(q).isOutgoing)
        XCTAssertTrue(ThreadItem.note(note("n", .outbound, sent: 3, received: 9)).isOutgoing)
        XCTAssertFalse(ThreadItem.note(note("n", .inbound, sent: 3, received: 9)).isOutgoing)
        XCTAssertTrue(ThreadItem.chat(chat("c", 1, out: true)).isOutgoing)
    }

    func testAscendingWithIdTieBreakAndStability() {
        let items = ThreadMerge.items(
            chat: [chat("b", 10), chat("a", 10), chat("z", 1)],
            notes: [note("m", .outbound, sent: 10, received: 99)], queued: [],
            oldestLoadedChatDate: nil, hasMoreChat: false)
        XCTAssertEqual(ids(items), ["chat:z", "chat:a", "chat:b", "note:m"])
        let again = ThreadMerge.items(chat: [chat("a", 10), chat("z", 1), chat("b", 10)],
                                      notes: [note("m", .outbound, sent: 10, received: 99)], queued: [],
                                      oldestLoadedChatDate: nil, hasMoreChat: false)
        XCTAssertEqual(ids(items), ids(again))
    }

    func testClockSkewInboundSortsByReceivedAt() {
        let n = note("n", .inbound, sent: -100_000, received: 50)
        let items = ThreadMerge.items(chat: [chat("a", 10), chat("b", 100)], notes: [n], queued: [],
                                      oldestLoadedChatDate: nil, hasMoreChat: false)
        XCTAssertEqual(ids(items), ["chat:a", "note:n", "chat:b"])
    }

    func testQueuedItemsInterleave() {
        let q = queued(20)
        let items = ThreadMerge.items(chat: [chat("a", 10), chat("b", 30)], notes: [], queued: [q],
                                      oldestLoadedChatDate: nil, hasMoreChat: false)
        XCTAssertEqual(ids(items), ["chat:a", "queued:\(q.id.uuidString)", "chat:b"])
    }

    func testHasMoreChatClampsNotesAndQueued() {
        let old = note("old", .outbound, sent: 1, received: 1)
        let edge = note("edge", .outbound, sent: 10, received: 10)
        let qOld = queued(2), qNew = queued(11)
        let items = ThreadMerge.items(chat: [chat("a", 10)], notes: [old, edge], queued: [qOld, qNew],
                                      oldestLoadedChatDate: t0.addingTimeInterval(10), hasMoreChat: true)
        XCTAssertEqual(ids(items), ["chat:a", "note:edge", "queued:\(qNew.id.uuidString)"])
        let all = ThreadMerge.items(chat: [chat("a", 10)], notes: [old, edge], queued: [qOld, qNew],
                                    oldestLoadedChatDate: t0.addingTimeInterval(10), hasMoreChat: false)
        XCTAssertEqual(all.count, 5)
    }

    func testHasMoreWithNilOldestIncludesAll() {
        let items = ThreadMerge.items(chat: [], notes: [note("n", .outbound, sent: 1, received: 1)], queued: [queued(2)],
                                      oldestLoadedChatDate: nil, hasMoreChat: true)
        XCTAssertEqual(items.count, 2)
    }

    func testDuplicateIDsCollapsed() {
        let n = note("n", .outbound, sent: 1, received: 1)
        let items = ThreadMerge.items(chat: [chat("a", 1), chat("a", 1)], notes: [n, n], queued: [],
                                      oldestLoadedChatDate: nil, hasMoreChat: false)
        XCTAssertEqual(ids(items), ["chat:a", "note:n"])
    }

    func testRunStartsAcrossChatAndNoteBoundaries() {
        // chat(out) then outbound note within gap: same speaker => same run
        let items = ThreadMerge.items(
            chat: [chat("a", 0, out: true), chat("c", 400, out: true)],
            notes: [note("n", .outbound, sent: 10, received: 10), note("i", .inbound, sent: 20, received: 20)],
            queued: [], oldestLoadedChatDate: nil, hasMoreChat: false)
        XCTAssertEqual(ids(items), ["chat:a", "note:n", "note:i", "chat:c"])
        let starts = ThreadMerge.runStartIDs(in: items, calendar: cal)
        XCTAssertEqual(starts, ["chat:a", "note:i", "chat:c"])
    }

    func testRunStartAfterGapAndEmpty() {
        XCTAssertEqual(ThreadMerge.runStartIDs(in: [], calendar: cal), [])
        let items = [ThreadItem.chat(chat("a", 0, out: true)), .chat(chat("b", 300, out: true)), .chat(chat("c", 601, out: true))]
        XCTAssertEqual(ThreadMerge.runStartIDs(in: items, calendar: cal), ["chat:a", "chat:c"])
    }

    func testDayStartsAcrossBoundaries() {
        let day: TimeInterval = 86_400
        let items = ThreadMerge.items(
            chat: [chat("a", 0), chat("b", day)],
            notes: [note("n", .inbound, sent: 0, received: day + 5)], queued: [],
            oldestLoadedChatDate: nil, hasMoreChat: false)
        let starts = ThreadMerge.dayStartIDs(in: items, calendar: cal)
        // t0 = 1_000_000 s => 11 days + 13_600 s UTC; +day is the next date
        XCTAssertEqual(starts, ["chat:a", "chat:b"])
    }
}
