// PeerDropKit/Tests/PeerDropCoreTests/ChatManagerEditDeleteOffscreenTests.swift
//
// Issue #158: an incoming edit/delete for a conversation that isn't open was
// silently lost. persistEditOrDelete copied the change from the on-screen
// `messages` array — which only holds the open conversation — so the stored
// message was written back unchanged.
import XCTest
@testable import PeerDropCore
import PeerDropSecurity

final class ChatManagerEditDeleteOffscreenTests: XCTestCase {
    private var keyDir: URL!
    private var root: URL!

    override func setUp() {
        super.setUp()
        keyDir = FileManager.default.temporaryDirectory.appendingPathComponent("cmoffkeys-\(UUID().uuidString)")
        PeerDropPersistence.fileStore = .init(directory: keyDir, namespace: "cmofftest")
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cmoff-\(UUID().uuidString)")
    }

    override func tearDown() {
        PeerDropPersistence.fileStore = nil
        try? FileManager.default.removeItem(at: keyDir)
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    @MainActor
    func test_editForOffscreenPeer_persists() throws {
        let manager = ChatManager(rootDirectory: root)
        manager.loadMessages(forPeer: "A") // conversation A is open
        _ = manager.saveIncoming(text: "original", peerID: "B", peerName: "B", messageID: "msg-b-1")

        let editedAt = Date(timeIntervalSince1970: 1_800_000_000)
        manager.applyEdit(messageID: "msg-b-1", newText: "edited", editedAt: editedAt, peerID: "B", origin: .remotePeer)
        manager.flushAllPendingPersists()

        manager.loadMessages(forPeer: "B")
        let msg = try XCTUnwrap(manager.messages.first { $0.id == "msg-b-1" })
        XCTAssertEqual(msg.text, "edited", "edit for a conversation that isn't open was lost")
        XCTAssertEqual(msg.editedAt, editedAt)
    }

    @MainActor
    func test_deleteForOffscreenPeer_persists() throws {
        let manager = ChatManager(rootDirectory: root)
        manager.loadMessages(forPeer: "A") // conversation A is open
        _ = manager.saveIncoming(text: "doomed", peerID: "B", peerName: "B", messageID: "msg-b-2")

        manager.applyDelete(messageID: "msg-b-2", peerID: "B", origin: .remotePeer)
        manager.flushAllPendingPersists()

        manager.loadMessages(forPeer: "B")
        let msg = try XCTUnwrap(manager.messages.first { $0.id == "msg-b-2" })
        XCTAssertTrue(msg.isDeleted, "delete for a conversation that isn't open was lost")
    }

    @MainActor
    func test_editForOpenConversation_persistsAndIsVisible() throws {
        let manager = ChatManager(rootDirectory: root)
        manager.loadMessages(forPeer: "B") // conversation B is open
        _ = manager.saveIncoming(text: "original", peerID: "B", peerName: "B", messageID: "msg-b-3")

        let editedAt = Date(timeIntervalSince1970: 1_800_000_100)
        manager.applyEdit(messageID: "msg-b-3", newText: "edited", editedAt: editedAt, peerID: "B", origin: .remotePeer)

        let onScreen = try XCTUnwrap(manager.messages.first { $0.id == "msg-b-3" })
        XCTAssertEqual(onScreen.text, "edited")
        XCTAssertEqual(onScreen.editedAt, editedAt)

        manager.flushAllPendingPersists()
        manager.loadMessages(forPeer: "A")
        manager.loadMessages(forPeer: "B")
        let reloaded = try XCTUnwrap(manager.messages.first { $0.id == "msg-b-3" })
        XCTAssertEqual(reloaded.text, "edited")
        XCTAssertEqual(reloaded.editedAt, editedAt)
    }

    // MARK: - Authorization: a peer may only edit/delete its own messages

    @MainActor
    private func storedMessage(_ id: String, peer: String, _ manager: ChatManager) throws -> ChatMessage {
        manager.flushAllPendingPersists()
        manager.loadMessages(forPeer: peer)
        return try XCTUnwrap(manager.messages.first { $0.id == id })
    }

    @MainActor
    func test_peerEdit_targetingAnotherPeersConversation_isIgnored() throws {
        let manager = ChatManager(rootDirectory: root)
        manager.loadMessages(forPeer: "C") // C's conversation is open
        _ = manager.saveIncoming(text: "C wrote this", peerID: "C", peerName: "C", messageID: "msg-c-1")
        manager.flushAllPendingPersists()

        manager.applyEdit(messageID: "msg-c-1", newText: "B was here", editedAt: Date(), peerID: "B", origin: .remotePeer)
        manager.applyDelete(messageID: "msg-c-1", peerID: "B", origin: .remotePeer)

        let onScreen = try XCTUnwrap(manager.messages.first { $0.id == "msg-c-1" })
        XCTAssertEqual(onScreen.text, "C wrote this", "peer B edited peer C's message in memory")
        XCTAssertFalse(onScreen.isDeleted, "peer B deleted peer C's message in memory")
        manager.loadMessages(forPeer: "A")
        let stored = try storedMessage("msg-c-1", peer: "C", manager)
        XCTAssertEqual(stored.text, "C wrote this", "peer B edited peer C's message on disk")
        XCTAssertNil(stored.editedAt)
        XCTAssertFalse(stored.isDeleted, "peer B deleted peer C's message on disk")
    }

    @MainActor
    func test_peerEdit_targetingMyOutgoingMessage_isIgnored() throws {
        let manager = ChatManager(rootDirectory: root)
        manager.loadMessages(forPeer: "B") // B's conversation is open
        let mine = manager.saveOutgoing(text: "I wrote this", peerID: "B", peerName: "B")

        manager.applyEdit(messageID: mine.id, newText: "B rewrote it", editedAt: Date(), peerID: "B", origin: .remotePeer)
        manager.applyDelete(messageID: mine.id, peerID: "B", origin: .remotePeer)

        let onScreen = try XCTUnwrap(manager.messages.first { $0.id == mine.id })
        XCTAssertEqual(onScreen.text, "I wrote this", "peer B edited my outgoing message in memory")
        XCTAssertFalse(onScreen.isDeleted, "peer B deleted my outgoing message in memory")
        manager.loadMessages(forPeer: "A")
        let stored = try storedMessage(mine.id, peer: "B", manager)
        XCTAssertEqual(stored.text, "I wrote this", "peer B edited my outgoing message on disk")
        XCTAssertFalse(stored.isDeleted, "peer B deleted my outgoing message on disk")
    }

    @MainActor
    func test_peerEdit_ofMessageWithDifferentSenderID_isIgnored() throws {
        let manager = ChatManager(rootDirectory: root)
        manager.loadMessages(forPeer: "A")
        _ = manager.saveIncoming(text: "X wrote this", peerID: "B", peerName: "B", senderID: "X", messageID: "msg-x-1")

        manager.applyEdit(messageID: "msg-x-1", newText: "B was here", editedAt: Date(), peerID: "B", origin: .remotePeer)

        let stored = try storedMessage("msg-x-1", peer: "B", manager)
        XCTAssertEqual(stored.text, "X wrote this", "peer B edited a message whose sender is X")
    }

    @MainActor
    func test_peerDelete_ofOwnMessage_onScreen_isApplied() throws {
        let manager = ChatManager(rootDirectory: root)
        manager.loadMessages(forPeer: "B")
        _ = manager.saveIncoming(text: "oops", peerID: "B", peerName: "B", messageID: "msg-b-4")

        manager.applyDelete(messageID: "msg-b-4", peerID: "B", origin: .remotePeer)

        XCTAssertTrue(try XCTUnwrap(manager.messages.first { $0.id == "msg-b-4" }).isDeleted)
        manager.loadMessages(forPeer: "A")
        XCTAssertTrue(try storedMessage("msg-b-4", peer: "B", manager).isDeleted)
    }

    @MainActor
    func test_localEdit_ofMyOutgoingMessage_offscreen_isApplied() throws {
        let manager = ChatManager(rootDirectory: root)
        manager.loadMessages(forPeer: "B")
        let mine = manager.saveOutgoing(text: "typo", peerID: "B", peerName: "B")
        manager.loadMessages(forPeer: "A") // B is no longer open

        manager.applyEdit(messageID: mine.id, newText: "fixed", editedAt: Date(), peerID: "B", origin: .localUser)
        manager.applyDelete(messageID: mine.id, peerID: "B", origin: .localUser)

        let stored = try storedMessage(mine.id, peer: "B", manager)
        XCTAssertEqual(stored.text, "fixed")
        XCTAssertTrue(stored.isDeleted)
    }

    @MainActor
    func test_localEdit_cannotRewriteAPeersMessage() throws {
        let manager = ChatManager(rootDirectory: root)
        manager.loadMessages(forPeer: "B")
        _ = manager.saveIncoming(text: "B wrote this", peerID: "B", peerName: "B", messageID: "msg-b-5")

        manager.applyEdit(messageID: "msg-b-5", newText: "I rewrote it", editedAt: Date(), peerID: "B", origin: .localUser)

        XCTAssertEqual(manager.messages.first { $0.id == "msg-b-5" }?.text, "B wrote this")
        manager.loadMessages(forPeer: "A")
        XCTAssertEqual(try storedMessage("msg-b-5", peer: "B", manager).text, "B wrote this")
    }
}
