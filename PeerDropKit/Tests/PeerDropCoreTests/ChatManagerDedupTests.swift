// PeerDropKit/Tests/PeerDropCoreTests/ChatManagerDedupTests.swift
//
// A duplicate delivery (direct + relay both arrive, a send retry, a reconnect
// replay) now carries the SAME shared id, so it can be deduped. Messages
// without a shared id (legacy senders) can't be, and must not be dropped.
import XCTest
@testable import PeerDropCore
import PeerDropSecurity

final class ChatManagerDedupTests: XCTestCase {
    private var keyDir: URL!

    override func setUp() {
        super.setUp()
        keyDir = FileManager.default.temporaryDirectory.appendingPathComponent("cmdedupkeys-\(UUID().uuidString)")
        PeerDropPersistence.fileStore = .init(directory: keyDir, namespace: "cmdeduptest")
    }

    override func tearDown() {
        PeerDropPersistence.fileStore = nil
        try? FileManager.default.removeItem(at: keyDir)
        super.tearDown()
    }

    @MainActor
    private func manager() -> ChatManager {
        let m = ChatManager(rootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        m.loadMessages(forPeer: "A")   // currentPeerID = A
        m.activeChatPeerID = "A"
        return m
    }

    @MainActor
    func test_duplicateSharedID_storedOnce() {
        let m = manager()
        _ = m.saveIncoming(text: "hi", peerID: "A", peerName: "A", messageID: "dup-1")
        _ = m.saveIncoming(text: "hi", peerID: "A", peerName: "A", messageID: "dup-1") // duplicate delivery
        XCTAssertEqual(m.messages.filter { $0.id == "dup-1" }.count, 1)
    }

    @MainActor
    func test_distinctSharedIDs_bothStored() {
        let m = manager()
        _ = m.saveIncoming(text: "a", peerID: "A", peerName: "A", messageID: "id-1")
        _ = m.saveIncoming(text: "b", peerID: "A", peerName: "A", messageID: "id-2")
        XCTAssertEqual(m.messages.count, 2)
    }

    @MainActor
    func test_legacyNoSharedID_notDeduped() {
        let m = manager()
        _ = m.saveIncoming(text: "a", peerID: "A", peerName: "A")
        _ = m.saveIncoming(text: "a", peerID: "A", peerName: "A")
        XCTAssertEqual(m.messages.count, 2, "legacy messages without a shared id must not be deduped")
    }
}
