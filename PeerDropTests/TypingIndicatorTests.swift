import XCTest
@testable import PeerDrop

/// Tests for typing indicator state management in ChatManager
@MainActor
final class TypingIndicatorTests: XCTestCase {

    var chatManager: ChatManager!

    override func setUp() async throws {
        try await super.setUp()
        chatManager = ChatManager()
    }

    override func tearDown() async throws {
        chatManager = nil
        try await super.tearDown()
    }

    // MARK: - Typing State Tests

    func testSetTypingAddsToTypingPeers() {
        XCTAssertFalse(chatManager.isTyping(peerID: "peer-1"))

        chatManager.setTyping(true, for: "peer-1")

        XCTAssertTrue(chatManager.isTyping(peerID: "peer-1"))
    }

    func testSetTypingFalseRemovesFromTypingPeers() {
        chatManager.setTyping(true, for: "peer-1")
        XCTAssertTrue(chatManager.isTyping(peerID: "peer-1"))

        chatManager.setTyping(false, for: "peer-1")

        XCTAssertFalse(chatManager.isTyping(peerID: "peer-1"))
    }

    func testMultiplePeersTyping() {
        chatManager.setTyping(true, for: "peer-1")
        chatManager.setTyping(true, for: "peer-2")
        chatManager.setTyping(true, for: "peer-3")

        XCTAssertTrue(chatManager.isTyping(peerID: "peer-1"))
        XCTAssertTrue(chatManager.isTyping(peerID: "peer-2"))
        XCTAssertTrue(chatManager.isTyping(peerID: "peer-3"))
        XCTAssertFalse(chatManager.isTyping(peerID: "peer-4"))
    }

    func testTypingPeersSetUpdatesCorrectly() {
        XCTAssertTrue(chatManager.typingPeers.isEmpty)

        chatManager.setTyping(true, for: "peer-1")
        XCTAssertEqual(chatManager.typingPeers.count, 1)
        XCTAssertTrue(chatManager.typingPeers.contains("peer-1"))

        chatManager.setTyping(true, for: "peer-2")
        XCTAssertEqual(chatManager.typingPeers.count, 2)

        chatManager.setTyping(false, for: "peer-1")
        XCTAssertEqual(chatManager.typingPeers.count, 1)
        XCTAssertFalse(chatManager.typingPeers.contains("peer-1"))
        XCTAssertTrue(chatManager.typingPeers.contains("peer-2"))
    }

    func testSetTypingTrueMultipleTimesForSamePeer() {
        chatManager.setTyping(true, for: "peer-1")
        chatManager.setTyping(true, for: "peer-1")
        chatManager.setTyping(true, for: "peer-1")

        XCTAssertEqual(chatManager.typingPeers.count, 1)
        XCTAssertTrue(chatManager.isTyping(peerID: "peer-1"))
    }

    func testSetTypingFalseForNonTypingPeer() {
        // Should not crash or have side effects
        chatManager.setTyping(false, for: "peer-nonexistent")
        XCTAssertFalse(chatManager.isTyping(peerID: "peer-nonexistent"))
        XCTAssertTrue(chatManager.typingPeers.isEmpty)
    }

    // MARK: - Typing Expiration Tests

    func testTypingExpiresAfterTimeout() async throws {
        chatManager.setTyping(true, for: "peer-1")
        XCTAssertTrue(chatManager.isTyping(peerID: "peer-1"))

        // Wait for expiration (5 seconds + buffer)
        try await Task.sleep(nanoseconds: 5_500_000_000)

        XCTAssertFalse(chatManager.isTyping(peerID: "peer-1"))
    }

    func testTypingRefreshResetsExpirationTimer() async throws {
        // Verify that calling setTyping(true) multiple times doesn't cause issues
        chatManager.setTyping(true, for: "peer-1")
        XCTAssertTrue(chatManager.isTyping(peerID: "peer-1"))

        // Small delay to simulate real usage
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds

        // Refresh typing
        chatManager.setTyping(true, for: "peer-1")

        // Should still be typing immediately after refresh
        XCTAssertTrue(chatManager.isTyping(peerID: "peer-1"))

        // Verify only one entry in typingPeers (refresh doesn't create duplicates)
        XCTAssertEqual(chatManager.typingPeers.count, 1)
    }

    func testSetTypingFalseCancelsExpirationTimer() async throws {
        chatManager.setTyping(true, for: "peer-1")
        chatManager.setTyping(false, for: "peer-1")

        XCTAssertFalse(chatManager.isTyping(peerID: "peer-1"))

        // Wait past expiration time
        try await Task.sleep(nanoseconds: 6_000_000_000)

        // Should still be not typing (no unexpected state changes)
        XCTAssertFalse(chatManager.isTyping(peerID: "peer-1"))
    }

    // MARK: - Unread Message IDs Tests

    func testGetUnreadMessageIDsReturnsIncomingNonReadMessages() async throws {
        let testPeerID = "test-peer-\(UUID().uuidString)"

        // Save some incoming messages (status will be .delivered by default)
        _ = chatManager.saveIncoming(text: "Message 1", peerID: testPeerID, peerName: "Test Peer")
        _ = chatManager.saveIncoming(text: "Message 2", peerID: testPeerID, peerName: "Test Peer")

        // Load messages to populate the in-memory array
        chatManager.loadMessages(forPeer: testPeerID)

        let unreadIDs = chatManager.getUnreadMessageIDs(for: testPeerID)

        // Should have 2 unread messages
        XCTAssertEqual(unreadIDs.count, 2)

        // Cleanup
        chatManager.deleteMessages(forPeer: testPeerID)
    }

    func testGetUnreadMessageIDsExcludesOutgoingMessages() async throws {
        let testPeerID = "test-peer-\(UUID().uuidString)"

        // Save outgoing message
        _ = chatManager.saveOutgoing(text: "Outgoing", peerID: testPeerID, peerName: "Test Peer")

        chatManager.loadMessages(forPeer: testPeerID)

        let unreadIDs = chatManager.getUnreadMessageIDs(for: testPeerID)

        // Should not include outgoing messages
        XCTAssertTrue(unreadIDs.isEmpty)

        // Cleanup
        chatManager.deleteMessages(forPeer: testPeerID)
    }

    func testGetUnreadMessageIDsExcludesReadMessages() async throws {
        let testPeerID = "test-peer-\(UUID().uuidString)"

        // Save incoming message
        let msg = chatManager.saveIncoming(text: "Message", peerID: testPeerID, peerName: "Test Peer")

        chatManager.loadMessages(forPeer: testPeerID)

        // Mark as read
        chatManager.updateStatus(messageID: msg.id, status: .read)

        let unreadIDs = chatManager.getUnreadMessageIDs(for: testPeerID)

        // Should be empty now
        XCTAssertTrue(unreadIDs.isEmpty)

        // Cleanup
        chatManager.deleteMessages(forPeer: testPeerID)
    }
}
