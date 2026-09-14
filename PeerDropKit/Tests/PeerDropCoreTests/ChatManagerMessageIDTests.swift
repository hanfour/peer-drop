// PeerDropKit/Tests/PeerDropCoreTests/ChatManagerMessageIDTests.swift
//
// The receiver must store an incoming message under the sender-provided id so
// both sides agree on it (delivery/read receipts, edits, deletes, reactions,
// dedup). With no id supplied (legacy sender) it falls back to minting one.
import XCTest
@testable import PeerDropCore
import PeerDropProtocol
import PeerDropSecurity

final class ChatManagerMessageIDTests: XCTestCase {
    private var keyDir: URL!

    override func setUp() {
        super.setUp()
        keyDir = FileManager.default.temporaryDirectory.appendingPathComponent("cmidkeys-\(UUID().uuidString)")
        PeerDropPersistence.fileStore = .init(directory: keyDir, namespace: "cmidtest")
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
    func test_saveIncoming_usesProvidedMessageID() {
        let msg = manager().saveIncoming(text: "hi", peerID: "A", peerName: "A", messageID: "shared-123")
        XCTAssertEqual(msg.id, "shared-123")
    }

    @MainActor
    func test_saveIncoming_withoutMessageID_mintsAnID() {
        let msg = manager().saveIncoming(text: "hi", peerID: "A", peerName: "A")
        XCTAssertFalse(msg.id.isEmpty)
        XCTAssertNotEqual(msg.id, "shared-123")
    }

    /// End-to-end: the sender's id rides the wire payload, the receiver stores
    /// the message under it, and a delivery receipt (carrying that shared id)
    /// updates the sender's own message — the whole point of the change.
    @MainActor
    func test_sharedID_makesDeliveryReceiptMatchSenderMessage() {
        let sender = manager()
        let receiver = manager()
        sender.loadMessages(forPeer: "R")          // currentPeerID = R, so the outgoing shows
        let out = sender.saveOutgoing(text: "hi", peerID: "R", peerName: "R")

        // Simulate the wire hop: the sender attaches its id; the receiver adopts it.
        let payload = TextMessagePayload(text: "hi", messageID: out.id)
        let stored = receiver.saveIncoming(text: payload.text, peerID: "S", peerName: "S",
                                           messageID: payload.messageID)
        XCTAssertEqual(stored.id, out.id, "receiver must store under the sender's id")

        // The receiver's delivery receipt echoes stored.id (== out.id).
        sender.updateStatus(messageID: stored.id, status: .delivered)
        XCTAssertEqual(sender.messages.first { $0.id == out.id }?.status, .delivered,
                       "delivery receipt id did not match the sender's message")
    }
}
