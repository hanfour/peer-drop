// PeerDropKit/Tests/PeerDropCoreTests/ChatManagerRoutingTests.swift
//
// An incoming message must land in its own conversation, not whichever chat
// happens to be open. appendMessage unconditionally pushed every message into
// the on-screen `messages` list, so a message from peer B leaked into peer A's
// open thread (and got marked read against A).
import XCTest
@testable import PeerDropCore
import PeerDropSecurity

final class ChatManagerRoutingTests: XCTestCase {
    private var keyDir: URL!

    override func setUp() {
        super.setUp()
        keyDir = FileManager.default.temporaryDirectory.appendingPathComponent("cmroutekeys-\(UUID().uuidString)")
        PeerDropPersistence.fileStore = .init(directory: keyDir, namespace: "cmroutetest")
    }

    override func tearDown() {
        PeerDropPersistence.fileStore = nil
        try? FileManager.default.removeItem(at: keyDir)
        super.tearDown()
    }

    @MainActor
    func test_incomingFromOtherPeer_doesNotLeakIntoOpenConversation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmroute-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ChatManager(rootDirectory: root)

        manager.loadMessages(forPeer: "A") // open conversation A (currentPeerID = A)
        manager.activeChatPeerID = "A"

        _ = manager.saveIncoming(text: "from B", peerID: "B", peerName: "B")

        XCTAssertFalse(manager.messages.contains { $0.text == "from B" },
                       "peer B's message leaked into peer A's open conversation")
    }

    @MainActor
    func test_incomingForOpenConversation_appears() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmroute2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ChatManager(rootDirectory: root)

        manager.loadMessages(forPeer: "A")
        manager.activeChatPeerID = "A"

        _ = manager.saveIncoming(text: "from A", peerID: "A", peerName: "A")

        XCTAssertTrue(manager.messages.contains { $0.text == "from A" },
                      "a message for the open conversation must still appear")
    }
}
