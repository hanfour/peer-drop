// PeerDropKit/Tests/PeerDropCoreTests/ChatManagerPersistenceTests.swift
//
// Persistence must not lose messages. Regression coverage for persistMessages
// clearing the pending queue before the risky decrypt/decode and then wedging
// every future write against an undecodable ("poison") file — the device-
// migration data-loss path (at-rest key gone, ciphertext still on disk).
import XCTest
@testable import PeerDropCore
import PeerDropSecurity

final class ChatManagerPersistenceTests: XCTestCase {
    private var keyDir: URL!

    override func setUp() {
        super.setUp()
        // Force headless file-backed at-rest key so ChatDataEncryptor works
        // without the keychain in the test process.
        keyDir = FileManager.default.temporaryDirectory.appendingPathComponent("cmkeys-\(UUID().uuidString)")
        PeerDropPersistence.fileStore = .init(directory: keyDir, namespace: "cmtest")
    }

    override func tearDown() {
        PeerDropPersistence.fileStore = nil
        try? FileManager.default.removeItem(at: keyDir)
        super.tearDown()
    }

    @MainActor
    func test_persist_withUndecodableExistingFile_stillSavesNewMessage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmroot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ChatManager(rootDirectory: root)
        manager.activeChatPeerID = "peerX"   // suppress unread bookkeeping noise

        // Plant a poison file: an existing chat file that cannot be decoded.
        let messagesDir = root.appendingPathComponent("ChatData/messages", isDirectory: true)
        try FileManager.default.createDirectory(at: messagesDir, withIntermediateDirectories: true)
        let poison = messagesDir.appendingPathComponent("peerX.json")
        try Data("undecodable garbage".utf8).write(to: poison)

        _ = manager.saveIncoming(text: "hello after migration", peerID: "peerX", peerName: "X")
        manager.flushAllPendingPersists()

        manager.loadMessages(forPeer: "peerX")
        XCTAssertTrue(manager.messages.contains { $0.text == "hello after migration" },
                      "new message lost — persistence wedged on the poison file")
    }
}
