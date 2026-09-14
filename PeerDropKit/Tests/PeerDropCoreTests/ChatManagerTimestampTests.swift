// PeerDropKit/Tests/PeerDropCoreTests/ChatManagerTimestampTests.swift
//
// Incoming messages must keep the sender's timestamp (carried on the wire),
// not be re-stamped with the receive time. Otherwise offline-queued / mailbox-
// delivered messages all collapse to "the moment they arrived" and sort by
// arrival instead of send order (wrong across time zones and catch-up bursts).
import XCTest
@testable import PeerDropCore
import PeerDropSecurity

final class ChatManagerTimestampTests: XCTestCase {
    private var keyDir: URL!

    override func setUp() {
        super.setUp()
        keyDir = FileManager.default.temporaryDirectory.appendingPathComponent("cmtskeys-\(UUID().uuidString)")
        PeerDropPersistence.fileStore = .init(directory: keyDir, namespace: "cmtstest")
    }

    override func tearDown() {
        PeerDropPersistence.fileStore = nil
        try? FileManager.default.removeItem(at: keyDir)
        super.tearDown()
    }

    @MainActor
    private func manager() -> ChatManager {
        ChatManager(rootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    @MainActor
    func test_saveIncoming_preservesSenderTimestamp() {
        let sent = Date(timeIntervalSince1970: 1_000_000)
        let msg = manager().saveIncoming(text: "hi", peerID: "A", peerName: "A", timestamp: sent)
        XCTAssertEqual(msg.timestamp, sent)
    }

    @MainActor
    func test_saveGroupIncoming_preservesSenderTimestamp() {
        let sent = Date(timeIntervalSince1970: 2_000_000)
        let msg = manager().saveGroupIncoming(text: "hi", groupID: "G", senderID: "B",
                                              senderName: "Bob", timestamp: sent)
        XCTAssertEqual(msg.timestamp, sent)
    }
}
