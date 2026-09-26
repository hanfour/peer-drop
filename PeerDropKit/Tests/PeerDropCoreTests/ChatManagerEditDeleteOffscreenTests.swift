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
        manager.applyEdit(messageID: "msg-b-1", newText: "edited", editedAt: editedAt, peerID: "B")
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

        manager.applyDelete(messageID: "msg-b-2", peerID: "B")
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
        manager.applyEdit(messageID: "msg-b-3", newText: "edited", editedAt: editedAt, peerID: "B")

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
}
