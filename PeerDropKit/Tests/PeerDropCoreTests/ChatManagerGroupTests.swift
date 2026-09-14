// PeerDropKit/Tests/PeerDropCoreTests/ChatManagerGroupTests.swift
//
// Received group messages must land in the GROUP store (group_messages/…,
// surfaced via `groupMessages`) that the group UI actually reads — not the
// 1-to-1 store. The receive path used to call saveIncoming(peerID: groupID),
// so other members' group messages never appeared. saveGroupIncoming is the
// correct sink; it was dead code until the routing fix.
import XCTest
@testable import PeerDropCore
import PeerDropSecurity

final class ChatManagerGroupTests: XCTestCase {
    private var keyDir: URL!

    override func setUp() {
        super.setUp()
        keyDir = FileManager.default.temporaryDirectory.appendingPathComponent("cmgrpkeys-\(UUID().uuidString)")
        PeerDropPersistence.fileStore = .init(directory: keyDir, namespace: "cmgrptest")
    }

    override func tearDown() {
        PeerDropPersistence.fileStore = nil
        try? FileManager.default.removeItem(at: keyDir)
        super.tearDown()
    }

    @MainActor
    func test_saveGroupIncoming_landsInGroupStoreWithSharedID() {
        let manager = ChatManager(rootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))

        _ = manager.saveGroupIncoming(text: "hi group", groupID: "G", senderID: "B",
                                      senderName: "Bob", messageID: "gm-1")

        // Reload from the group store the group UI reads.
        manager.loadGroupMessages(forGroup: "G")
        XCTAssertTrue(manager.groupMessages.contains { $0.id == "gm-1" && $0.text == "hi group" },
                      "received group message did not reach the group store")
    }
}
