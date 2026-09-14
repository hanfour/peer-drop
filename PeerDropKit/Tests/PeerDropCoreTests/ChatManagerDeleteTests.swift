// PeerDropKit/Tests/PeerDropCoreTests/ChatManagerDeleteTests.swift
//
// Deleting a conversation must fully forget it: no debounced write may recreate
// the file (a privacy failure) and no in-memory cache may resurrect it via
// Load-earlier.
import XCTest
@testable import PeerDropCore
import PeerDropSecurity

final class ChatManagerDeleteTests: XCTestCase {
    private var keyDir: URL!

    override func setUp() {
        super.setUp()
        keyDir = FileManager.default.temporaryDirectory.appendingPathComponent("cmdelkeys-\(UUID().uuidString)")
        PeerDropPersistence.fileStore = .init(directory: keyDir, namespace: "cmdeltest")
    }

    override func tearDown() {
        PeerDropPersistence.fileStore = nil
        try? FileManager.default.removeItem(at: keyDir)
        super.tearDown()
    }

    @MainActor
    func test_delete_afterIncomingWithinDebounce_doesNotRecreateFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmdel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ChatManager(rootDirectory: root)
        manager.activeChatPeerID = "peerY"

        _ = manager.saveIncoming(text: "secret", peerID: "peerY", peerName: "Y") // queued, not yet on disk
        manager.deleteMessages(forPeer: "peerY")
        manager.flushAllPendingPersists() // must not resurrect the deleted file

        let file = root.appendingPathComponent("ChatData/messages/peerY.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path),
                       "deleted conversation resurrected from the pending queue")
    }

    @MainActor
    func test_delete_currentConversation_clearsLoadEarlierCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmdel2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ChatManager(rootDirectory: root)
        manager.activeChatPeerID = "peerZ"

        _ = manager.saveIncoming(text: "one", peerID: "peerZ", peerName: "Z")
        manager.flushAllPendingPersists()
        manager.loadMessages(forPeer: "peerZ") // populates the in-memory cache
        XCTAssertFalse(manager.messages.isEmpty)

        manager.deleteMessages(forPeer: "peerZ")

        XCTAssertTrue(manager.messages.isEmpty, "current conversation not cleared from memory")
        XCTAssertFalse(manager.hasMoreMessages, "deleted conversation can still Load-earlier from the memory cache")
    }
}
