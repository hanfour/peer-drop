import XCTest
@testable import PeerDropCore
import PeerDropSecurity
import PeerDropNotes

final class ConversationSummaryTests: XCTestCase {
    private var keyDir: URL!
    private var root: URL!

    override func setUp() {
        super.setUp()
        keyDir = FileManager.default.temporaryDirectory.appendingPathComponent("cskeys-\(UUID().uuidString)")
        PeerDropPersistence.fileStore = .init(directory: keyDir, namespace: "cstest")
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cs-\(UUID().uuidString)")
    }

    override func tearDown() {
        PeerDropPersistence.fileStore = nil
        try? FileManager.default.removeItem(at: keyDir)
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    @MainActor
    func testSummaryOfPeerWithMessagesReturnsLast() {
        let m = ChatManager(rootDirectory: root)
        _ = m.saveOutgoing(text: "one", peerID: "p", peerName: "P")
        _ = m.saveOutgoing(text: "two", peerID: "p", peerName: "P")
        m.flushAllPendingPersists()
        let s = m.summary(forPeer: "p")
        XCTAssertEqual(s.lastMessage?.text, "two")
        XCTAssertEqual(s.lastActivity, s.lastMessage?.timestamp)
        XCTAssertFalse(s.isGroup)
    }

    @MainActor
    func testSummaryOfPeerWithoutFileHasNilLast() {
        let m = ChatManager(rootDirectory: root)
        let s = m.summary(forPeer: "none")
        XCTAssertNil(s.lastMessage)
        XCTAssertNil(s.lastActivity)
    }

    @MainActor
    func testPendingMessageIsVisibleBeforeFlush() {
        let m = ChatManager(rootDirectory: root)
        _ = m.saveOutgoing(text: "fresh", peerID: "p", peerName: "P")
        XCTAssertEqual(m.summary(forPeer: "p").lastMessage?.text, "fresh")
    }

    @MainActor
    func testSummaryDoesNotChangeActiveChat() {
        let m = ChatManager(rootDirectory: root)
        _ = m.saveOutgoing(text: "x", peerID: "p", peerName: "P")
        m.flushAllPendingPersists()
        m.activeChatPeerID = "other"
        let before = m.messages.map(\.id)
        _ = m.summary(forPeer: "p")
        XCTAssertEqual(m.messages.map(\.id), before)
        XCTAssertEqual(m.activeChatPeerID, "other")
    }

    @MainActor
    func testCacheRefreshesWhenFileChanges() {
        let m = ChatManager(rootDirectory: root)
        _ = m.saveOutgoing(text: "a", peerID: "p", peerName: "P")
        m.flushAllPendingPersists()
        XCTAssertEqual(m.summary(forPeer: "p").lastMessage?.text, "a")
        _ = m.saveOutgoing(text: "b", peerID: "p", peerName: "P")
        m.flushAllPendingPersists()
        XCTAssertEqual(m.summary(forPeer: "p").lastMessage?.text, "b")
    }

    @MainActor
    func testDeletedPeerHasNilLast() {
        let m = ChatManager(rootDirectory: root)
        _ = m.saveOutgoing(text: "a", peerID: "p", peerName: "P")
        m.flushAllPendingPersists()
        XCTAssertNotNil(m.summary(forPeer: "p").lastMessage)
        m.deleteMessages(forPeer: "p")
        XCTAssertNil(m.summary(forPeer: "p").lastMessage)
    }

    @MainActor
    func testGroupSummary() {
        let m = ChatManager(rootDirectory: root)
        let gid = "g-\(UUID().uuidString)" // unread counts persist in UserDefaults
        _ = m.saveGroupOutgoing(text: "hi group", groupID: gid, localName: "Me")
        m.incrementGroupUnread(groupID: gid)
        let s = m.summary(forGroup: gid)
        XCTAssertTrue(s.isGroup)
        XCTAssertEqual(s.lastMessage?.text, "hi group")
        XCTAssertEqual(s.unread, 1)
    }

    func testPreviewTexts() {
        func msg(text: String? = nil, media: String? = nil, file: String? = nil, deleted: Bool = false) -> ChatMessage {
            var m = ChatMessage(id: UUID().uuidString, text: text, isMedia: media != nil, mediaType: media,
                                fileName: file, fileSize: nil, mimeType: nil, duration: nil, thumbnailData: nil,
                                localFileURL: nil, isOutgoing: true, peerName: "P", status: .sent, timestamp: Date())
            m.isDeleted = deleted
            return m
        }
        XCTAssertEqual(ConversationPreview.text(for: msg(text: "hello")), "hello")
        XCTAssertEqual(ConversationPreview.text(for: msg(text: "secret", deleted: true)), "Message deleted")
        XCTAssertEqual(ConversationPreview.text(for: msg(media: "image", file: "a.jpg")), "📷 Photo")
        XCTAssertEqual(ConversationPreview.text(for: msg(media: "voice", file: "v.m4a")), "🎙 Voice message")
        XCTAssertEqual(ConversationPreview.text(for: msg(media: "file", file: "doc.pdf")), "📄 doc.pdf")
        XCTAssertEqual(ConversationPreview.text(for: msg(media: "video", file: "m.mov")), "🎞 Video")
        XCTAssertEqual(ConversationPreview.text(for: msg(media: "weird")), "Attachment")
    }

    @MainActor
    func testSameSizeRewriteRefreshesSummary() {
        let m = ChatManager(rootDirectory: root)
        let msg = m.saveOutgoing(text: "aaa", peerID: "p", peerName: "P")
        m.flushAllPendingPersists()
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        m.applyEdit(messageID: msg.id, newText: "bbb", editedAt: at, peerID: "p", origin: .localUser)
        m.flushAllPendingPersists()
        XCTAssertEqual(m.summary(forPeer: "p").lastMessage?.text, "bbb")
        m.applyEdit(messageID: msg.id, newText: "ccc", editedAt: at, peerID: "p", origin: .localUser)
        m.flushAllPendingPersists()
        XCTAssertEqual(m.summary(forPeer: "p").lastMessage?.text, "ccc")
    }

    @MainActor
    func testDeleteClearsCacheImmediately() {
        let m = ChatManager(rootDirectory: root)
        _ = m.saveOutgoing(text: "a", peerID: "p", peerName: "P")
        m.flushAllPendingPersists()
        _ = m.summary(forPeer: "p")
        m.deleteMessages(forPeer: "p")
        XCTAssertNil(m.summary(forPeer: "p").lastMessage)
        _ = m.saveGroupOutgoing(text: "g", groupID: "g", localName: "Me")
        XCTAssertNotNil(m.summary(forGroup: "g").lastMessage)
        m.deleteGroupMessages(forGroup: "g")
        XCTAssertNil(m.summary(forGroup: "g").lastMessage)
    }

    @MainActor
    func testCorruptFileYieldsNilLast() throws {
        let m = ChatManager(rootDirectory: root)
        let dir = root.appendingPathComponent("ChatData/messages")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not encrypted garbage".utf8).write(to: dir.appendingPathComponent("bad.json"))
        XCTAssertNil(m.summary(forPeer: "bad").lastMessage)
    }

    // MARK: note-aware summaries

    private func noteRec(_ dir: NoteDirection, sent: TimeInterval, received: TimeInterval, text: String? = "hello") -> NoteRecord {
        let t = Date(timeIntervalSince1970: 1_000_000)
        return NoteRecord(id: "n", direction: dir, text: text, sentAt: t.addingTimeInterval(sent), sender: .anonymous,
                          recipientAccountId: nil, readAt: nil, receivedAt: t.addingTimeInterval(received))
    }
    private func msg(_ off: TimeInterval) -> ChatMessage {
        ChatMessage.text(text: "m", isOutgoing: false, peerName: "p", timestamp: Date(timeIntervalSince1970: 1_000_000 + off))
    }

    func testLastActivityIsNewerOfMessageAndNote() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(ConversationSummary(id: "a", isGroup: false, lastMessage: msg(10), lastNote: noteRec(.inbound, sent: 0, received: 50), unread: 0).lastActivity, t.addingTimeInterval(50))
        XCTAssertEqual(ConversationSummary(id: "a", isGroup: false, lastMessage: msg(100), lastNote: noteRec(.outbound, sent: 50, received: 999), unread: 0).lastActivity, t.addingTimeInterval(100))
        XCTAssertEqual(ConversationSummary(id: "a", isGroup: false, lastMessage: nil, lastNote: noteRec(.outbound, sent: 7, received: 999), unread: 0).lastActivity, t.addingTimeInterval(7))
        XCTAssertNil(ConversationSummary(id: "a", isGroup: false, lastMessage: nil, lastNote: nil, unread: 0).lastActivity)
    }

    func testUnreadIsPassedThroughUnchanged() {
        XCTAssertEqual(ConversationSummary(id: "a", isGroup: false, lastMessage: msg(1), lastNote: noteRec(.inbound, sent: 0, received: 2), unread: 3).unread, 3)
    }

    func testLegacyInitHasNoNote() {
        let s = ConversationSummary(id: "a", isGroup: false, lastMessage: msg(1), unread: 1)
        XCTAssertNil(s.lastNote)
        XCTAssertEqual(s.lastActivity, msg(1).timestamp)
    }

    func testEqualityCoversNote() {
        let a = ConversationSummary(id: "a", isGroup: false, lastMessage: nil, lastNote: noteRec(.inbound, sent: 0, received: 5), unread: 0)
        let b = ConversationSummary(id: "a", isGroup: false, lastMessage: nil, lastNote: noteRec(.inbound, sent: 0, received: 5), unread: 0)
        let c = ConversationSummary(id: "a", isGroup: false, lastMessage: nil, lastNote: noteRec(.inbound, sent: 0, received: 5, text: "other"), unread: 0)
        let d = ConversationSummary(id: "a", isGroup: false, lastMessage: nil, lastNote: nil, unread: 0)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertNotEqual(a, d)
    }

    func testNotePreview() {
        XCTAssertEqual(ConversationPreview.text(for: noteRec(.inbound, sent: 0, received: 0)), "📮 hello")
        XCTAssertEqual(ConversationPreview.text(for: noteRec(.inbound, sent: 0, received: 0, text: nil)), "")
    }
}
