import XCTest
import CryptoKit
import Combine
import PeerDropSecurity
import PeerDropNotes
@testable import PeerDropCore
@testable import PeerDrop

@MainActor
final class ThreadModelTests: XCTestCase {
    private let peerID = "peer-thread-\(UUID().uuidString)"
    private let key = Data(repeating: 7, count: 32)
    private let friend = "FRND2345"
    private let t0 = Date(timeIntervalSince1970: 2_000_000)

    private var chat: ChatManager!
    private var outbox: NoteOutboxStore!
    private var outboxDir: URL!
    private var contacts: [TrustedContact] = []
    private var presence: PeerPresence = .offline
    private var accountReady = true
    private var model: ThreadModel!
    private let signal = PassthroughSubject<Void, Never>()

    override func setUp() async throws {
        try await super.setUp()
        chat = ChatManager()
        chat.deleteMessages(forPeer: peerID)
        chat.loadMessages(forPeer: peerID)
        outboxDir = FileManager.default.temporaryDirectory.appendingPathComponent("tm-\(UUID().uuidString)")
        outbox = NoteOutboxStore(directory: outboxDir, encryptor: ChatDataEncryptor(testKey: SymmetricKey(size: .bits256)))
        contacts = [bound()]
        model = ThreadModel()
    }

    override func tearDown() async throws {
        chat.deleteMessages(forPeer: peerID)
        try? FileManager.default.removeItem(at: outboxDir)
        model = nil
        try await super.tearDown()
    }

    private func bound(account: String? = "FRND2345", pending: Bool = false) -> TrustedContact {
        TrustedContact(deviceId: peerID, displayName: "Friend", identityPublicKey: key, trustLevel: .unknown, accountId: account,
                       pendingAccountBinding: pending ? PendingAccountBinding(accountId: "OTHR2345", signingKey: Data(repeating: 1, count: 32),
                                                                              handshakeKeyHash: Data(repeating: 2, count: 32), receivedAt: t0) : nil)
    }

    private func note(_ id: String, _ dir: NoteDirection, at offset: TimeInterval, sender: NoteSenderState? = nil,
                      to account: String? = nil, read: Bool = true) -> NoteRecord {
        let at = t0.addingTimeInterval(offset)
        return NoteRecord(id: id, direction: dir, text: "text \(id)", sentAt: at,
                          sender: sender ?? (dir == .inbound ? .verified(accountId: friend, nickname: nil) : .verified(accountId: "ME000001", nickname: nil)),
                          recipientAccountId: dir == .outbound ? (account ?? friend) : nil,
                          readAt: read ? at : nil, receivedAt: at)
    }

    private func attach(inbox: [NoteRecord] = [], sent: [NoteRecord] = [], throttle: TimeInterval = 0.01) -> NotesStore {
        let store = NotesStore(mockInbox: inbox, sent: sent)
        let binding = FriendBinding(contacts: { [unowned self] in self.contacts }, live: { _ in .none })
        model.attach(peerID: peerID, chatManager: chat, notesStore: store, outbox: outbox, friend: binding,
                     presence: { [unowned self] in self.presence }, accountReady: { [unowned self] in self.accountReady },
                     signals: [signal.eraseToAnyPublisher()], throttle: throttle)
        return store
    }

    private func waitUntil(_ what: String = "condition", _ cond: () -> Bool) async {
        for _ in 0..<200 {
            if cond() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out: \(what)")
    }

    private func chatMessage(_ text: String, at offset: TimeInterval) {
        _ = chat.saveIncoming(text: text, peerID: peerID, peerName: "Friend", timestamp: t0.addingTimeInterval(offset))
    }

    // MARK: merge

    func testMergesChatNotesAndOutboxByDate() {
        chatMessage("hi", at: 10)
        _ = attach(inbox: [note("n1", .inbound, at: 20)], sent: [note("n2", .outbound, at: 30)])
        outbox.enqueue(contactID: contacts[0].id, accountId: friend, expectedIdentityKey: key, text: "later", now: t0.addingTimeInterval(40))
        model.refresh()
        XCTAssertEqual(model.items.map(\.id).prefix(3), ["chat:" + chat.messages[0].id, "note:n1", "note:n2"])
        XCTAssertEqual(model.items.count, 4)
        XCTAssertEqual(model.queuedEntries.count, 1)
    }

    func testOnlyVerifiedBoundAccountNotesAreMerged() {
        let other = note("x1", .inbound, at: 1, sender: .verified(accountId: "OTHR2345", nickname: nil))
        let unverified = note("x2", .inbound, at: 2, sender: .unverified(accountId: friend))
        let anon = note("x3", .inbound, at: 3, sender: .anonymous)
        let good = note("ok", .inbound, at: 4)
        let toOther = note("x4", .outbound, at: 5, to: "OTHR2345")
        _ = attach(inbox: [other, unverified, anon, good], sent: [toOther])
        XCTAssertEqual(model.items.map(\.id), ["note:ok"])
    }

    func testPendingBindingShowsNoNotesAndLocks() {
        contacts = [bound(pending: true)]
        _ = attach(inbox: [note("n1", .inbound, at: 1)])
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(model.binding, .pending)
        XCTAssertEqual(model.decision, .locked(reason: .verifying))
    }

    func testNoBindingShowsNoNotes() {
        contacts = [bound(account: nil)]
        _ = attach(inbox: [note("n1", .inbound, at: 1)])
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(model.decision, .locked(reason: .notExchanged))
    }

    func testClampsNotesOlderThanOldestLoadedChatWhileMoreChatExists() {
        for i in 0..<60 { chatMessage("m\(i)", at: 1_000 + Double(i)) }   // 60 > page of 50
        chat.loadMessages(forPeer: peerID)
        XCTAssertTrue(chat.hasMoreMessages)
        let oldest = chat.messages.first!.timestamp
        let older = note("old", .inbound, at: 100)
        XCTAssertLessThan(older.threadDate, oldest)
        _ = attach(inbox: [older, note("new", .inbound, at: 5_000)])
        XCTAssertFalse(model.items.contains { $0.id == "note:old" })
        XCTAssertTrue(model.items.contains { $0.id == "note:new" })
        chat.loadMoreMessages()
        model.refresh()
        XCTAssertTrue(model.items.contains { $0.id == "note:old" }, "loading earlier chat extends the notes range")
    }

    // MARK: rebuild triggers

    func testRebuildsOnlyWhenASourceChanges() async {
        _ = attach()
        let base = model.rebuildCount
        presence = .online
        signal.send(())                                   // presence / account style signal
        await waitUntil("decision live") { model.decision == .live }
        XCTAssertEqual(model.rebuildCount, base, "a decision-only change must not rebuild the merged list")

        chatMessage("one", at: 1); chatMessage("two", at: 2); chatMessage("three", at: 3)
        await waitUntil("items") { model.items.count == 3 }
        XCTAssertEqual(model.rebuildCount, base + 1, "a burst is coalesced into one rebuild")
    }

    func testOutboxAndNotesChangesRebuild() async {
        let store = attach(inbox: [note("n1", .inbound, at: 1, read: false)])
        let base = model.rebuildCount
        XCTAssertEqual(model.unreadNoteIDs, ["n1"])
        await store.markRead("n1")
        await waitUntil("read") { model.unreadNoteIDs.isEmpty }
        XCTAssertGreaterThan(model.rebuildCount, base)

        let before = model.rebuildCount
        outbox.enqueue(contactID: contacts[0].id, accountId: friend, expectedIdentityKey: key, text: "q")
        await waitUntil("queued") { model.queuedEntries.count == 1 }
        XCTAssertGreaterThan(model.rebuildCount, before)
    }

    func testMarkVisibleNotesReadMarksBoundInbound() async {
        let store = attach(inbox: [note("n1", .inbound, at: 1, read: false), note("n2", .inbound, at: 2, read: false)])
        await model.markVisibleNotesRead()
        XCTAssertEqual(store.unreadCount(forAccount: friend), 0)
    }

    // MARK: queued / failed

    func testQueuedAndFailedEntriesPresented() async {
        _ = attach()
        let a = outbox.enqueue(contactID: contacts[0].id, accountId: friend, expectedIdentityKey: key, text: "a")
        let b = outbox.enqueue(contactID: contacts[0].id, accountId: friend, expectedIdentityKey: key, text: "b")
        outbox.markFailed(id: b.id, reason: "對方信箱已滿")
        await waitUntil("entries") { model.failedEntries.count == 1 && model.queuedEntries.count == 1 }
        XCTAssertEqual(model.queuedEntries.first?.id, a.id)
        XCTAssertEqual(NoteOutboxFailure(reason: model.failedEntries.first?.failReason), .inboxFull)
        XCTAssertEqual(model.items.filter { if case .queued = $0 { return true } else { return false } }.count, 2)
    }

    func testOtherContactsOutboxEntriesAreNotShown() async {
        _ = attach()
        outbox.enqueue(contactID: UUID(), accountId: friend, expectedIdentityKey: key, text: "elsewhere")
        model.refresh()
        XCTAssertTrue(model.queuedEntries.isEmpty)
    }

    // MARK: mode flips

    func testReplyIsClearedWhenModeLeavesLive() {
        presence = .online
        _ = attach()
        XCTAssertEqual(model.decision, .live)
        chatMessage("hello", at: 1)
        model.replyingToMessage = chat.messages.first
        model.refresh()
        XCTAssertNotNil(model.replyingToMessage, "stays while live")
        presence = .offline
        model.refresh()
        XCTAssertEqual(model.decision, .note(canSendNow: true))
        XCTAssertNil(model.replyingToMessage)
    }

    func testNoteCanSendNowFollowsAccountReadiness() {
        _ = attach()
        XCTAssertEqual(model.decision, .note(canSendNow: true))
        accountReady = false
        model.refresh()
        XCTAssertEqual(model.decision, .note(canSendNow: false))
        XCTAssertTrue(model.mode.queuesUntilOnline)
    }

    // MARK: composer mode mapping

    func testComposerModeMapping() {
        let live = ComposerMode(.live)
        XCTAssertTrue(live.isLive); XCTAssertTrue(live.acceptsInput); XCTAssertTrue(live.showsLiveControls)

        let note = ComposerMode(.note(canSendNow: true))
        XCTAssertTrue(note.isNote); XCTAssertTrue(note.acceptsInput)
        XCTAssertFalse(note.showsLiveControls); XCTAssertFalse(note.queuesUntilOnline)

        let queued = ComposerMode(.note(canSendNow: false))
        XCTAssertTrue(queued.isNote); XCTAssertTrue(queued.queuesUntilOnline)

        for reason in [LockReason.notExchanged, .verifying] {
            let locked = ComposerMode(.locked(reason: reason))
            XCTAssertTrue(locked.isLocked); XCTAssertFalse(locked.acceptsInput); XCTAssertFalse(locked.showsLiveControls)
        }
    }

    func testNoteCounterCountsUnicodeScalars() {
        XCTAssertFalse(ComposerMode.showsCounter(forText: String(repeating: "a", count: 1_799)))
        XCTAssertTrue(ComposerMode.showsCounter(forText: String(repeating: "a", count: 1_800)))
        XCTAssertFalse(ComposerMode.isOverLimit(String(repeating: "a", count: 2_000)))
        XCTAssertTrue(ComposerMode.isOverLimit(String(repeating: "a", count: 2_001)))
        // Emoji are one scalar each here; a family emoji is several, matching the server's count.
        XCTAssertEqual(ComposerMode.scalarCount("😀😀"), 2)
        XCTAssertGreaterThan(ComposerMode.scalarCount("👨‍👩‍👧"), 1)
    }

    func testStatusMappingForBubbles() {
        let id = UUID()
        let entry = NoteOutboxEntry(id: id, contactID: UUID(), accountId: friend, expectedIdentityKey: key, text: "x")
        XCTAssertEqual(NoteBubbleStatus.status(for: .queued(entry), sendingIDs: []), .queued)
        XCTAssertEqual(NoteBubbleStatus.status(for: .queued(entry), sendingIDs: [id]), .sending)
        var failed = entry; failed.state = .failed; failed.failReason = "綁定已取消"
        XCTAssertEqual(NoteBubbleStatus.status(for: .queued(failed), sendingIDs: []), .failed(.bindingCancelled))
        XCTAssertEqual(NoteBubbleStatus.status(for: .note(note("a", .outbound, at: 1)), sendingIDs: []), .sentToMailbox)
        XCTAssertEqual(NoteBubbleStatus.status(for: .note(note("b", .inbound, at: 1)), sendingIDs: []), .received)
    }
}
