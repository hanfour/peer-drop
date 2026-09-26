// PeerDropKit/Tests/PeerDropCoreTests/ChatManagerEditReactionTests.swift
//
// Edits, deletes and reactions applied while a message is still in the 500ms
// debounce queue must survive. persistReaction / persistEditOrDelete scanned
// disk without flushing pending first, so the change no-op'd and the debounce
// later wrote the original — the edit/reaction silently reverted.
import XCTest
@testable import PeerDropCore
import PeerDropSecurity

final class ChatManagerEditReactionTests: XCTestCase {
    private var keyDir: URL!

    override func setUp() {
        super.setUp()
        keyDir = FileManager.default.temporaryDirectory.appendingPathComponent("cmerkeys-\(UUID().uuidString)")
        PeerDropPersistence.fileStore = .init(directory: keyDir, namespace: "cmertest")
    }

    override func tearDown() {
        PeerDropPersistence.fileStore = nil
        try? FileManager.default.removeItem(at: keyDir)
        super.tearDown()
    }

    @MainActor
    func test_edit_withinDebounceWindow_persists() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ChatManager(rootDirectory: root)
        manager.loadMessages(forPeer: "A")
        manager.activeChatPeerID = "A"

        let msg = manager.saveOutgoing(text: "typo", peerID: "A", peerName: "A") // queued, not on disk
        manager.applyEdit(messageID: msg.id, newText: "fixed", editedAt: Date(), peerID: "A", origin: .localUser)

        manager.flushAllPendingPersists()
        manager.loadMessages(forPeer: "A")
        let reloaded = manager.messages.first { $0.id == msg.id }
        XCTAssertEqual(reloaded?.text, "fixed", "edit within the debounce window was lost")
    }

    @MainActor
    func test_reaction_withinDebounceWindow_persists() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmer2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ChatManager(rootDirectory: root)
        manager.loadMessages(forPeer: "A")
        manager.activeChatPeerID = "A"

        let msg = manager.saveOutgoing(text: "hi", peerID: "A", peerName: "A") // queued, not on disk
        manager.addReaction(emoji: "👍", to: msg.id, from: "B")

        manager.flushAllPendingPersists()
        manager.loadMessages(forPeer: "A")
        let reloaded = manager.messages.first { $0.id == msg.id }
        XCTAssertEqual(reloaded?.reactions?["👍"], ["B"], "reaction within the debounce window was lost")
    }
}
