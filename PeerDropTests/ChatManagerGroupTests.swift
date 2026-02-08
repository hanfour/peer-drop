import XCTest
@testable import PeerDrop

/// Tests for ChatManager group messaging functionality
@MainActor
final class ChatManagerGroupTests: XCTestCase {

    var chatManager: ChatManager!
    var testGroupID: String!

    override func setUp() async throws {
        try await super.setUp()
        chatManager = ChatManager()
        testGroupID = "test-group-\(UUID().uuidString)"

        // Ensure clean state
        chatManager.deleteGroupMessages(forGroup: testGroupID)
    }

    override func tearDown() async throws {
        // Clean up test data
        if let groupID = testGroupID {
            chatManager.deleteGroupMessages(forGroup: groupID)
        }
        chatManager = nil
        testGroupID = nil
        try await super.tearDown()
    }

    // MARK: - Group Message Creation

    func testSaveGroupOutgoingMessage() async throws {
        let message = chatManager.saveGroupOutgoing(
            text: "Hello group!",
            groupID: testGroupID,
            localName: "TestDevice"
        )

        XCTAssertEqual(message.text, "Hello group!")
        XCTAssertTrue(message.isOutgoing)
        XCTAssertEqual(message.groupID, testGroupID)
        XCTAssertEqual(message.senderName, "TestDevice")
        XCTAssertTrue(message.isGroupMessage)
    }

    func testSaveGroupIncomingMessage() async throws {
        let message = chatManager.saveGroupIncoming(
            text: "Hi from peer!",
            groupID: testGroupID,
            senderID: "peer-123",
            senderName: "Peer Device"
        )

        XCTAssertEqual(message.text, "Hi from peer!")
        XCTAssertFalse(message.isOutgoing)
        XCTAssertEqual(message.groupID, testGroupID)
        XCTAssertEqual(message.senderID, "peer-123")
        XCTAssertEqual(message.senderName, "Peer Device")
        XCTAssertTrue(message.isGroupMessage)
    }

    // MARK: - Group Message Persistence

    func testGroupMessagePersistence() async throws {
        // Save some messages
        chatManager.saveGroupOutgoing(text: "Message 1", groupID: testGroupID, localName: "Me")
        chatManager.saveGroupIncoming(text: "Message 2", groupID: testGroupID, senderID: "peer-1", senderName: "Peer 1")
        chatManager.saveGroupOutgoing(text: "Message 3", groupID: testGroupID, localName: "Me")

        // Verify in-memory messages
        XCTAssertEqual(chatManager.groupMessages.count, 3)

        // Create new ChatManager and load messages
        let newManager = ChatManager()
        newManager.loadGroupMessages(forGroup: testGroupID)

        XCTAssertEqual(newManager.groupMessages.count, 3)
        XCTAssertEqual(newManager.groupMessages[0].text, "Message 1")
        XCTAssertEqual(newManager.groupMessages[1].text, "Message 2")
        XCTAssertEqual(newManager.groupMessages[2].text, "Message 3")
    }

    // MARK: - Group Unread Count

    func testGroupUnreadCountIncrement() async throws {
        // No active group, so incoming should increment unread
        chatManager.activeGroupID = nil

        chatManager.saveGroupIncoming(text: "Unread 1", groupID: testGroupID, senderID: "p1", senderName: "Peer")
        chatManager.saveGroupIncoming(text: "Unread 2", groupID: testGroupID, senderID: "p1", senderName: "Peer")

        XCTAssertEqual(chatManager.groupUnreadCount(for: testGroupID), 2)
    }

    func testGroupUnreadNotIncrementedWhenActive() async throws {
        // Set active group
        chatManager.activeGroupID = testGroupID

        chatManager.saveGroupIncoming(text: "Active message", groupID: testGroupID, senderID: "p1", senderName: "Peer")

        // Should not increment when group is active
        XCTAssertEqual(chatManager.groupUnreadCount(for: testGroupID), 0)
    }

    func testMarkGroupAsRead() async throws {
        chatManager.activeGroupID = nil
        chatManager.saveGroupIncoming(text: "Msg 1", groupID: testGroupID, senderID: "p1", senderName: "Peer")
        chatManager.saveGroupIncoming(text: "Msg 2", groupID: testGroupID, senderID: "p1", senderName: "Peer")

        XCTAssertEqual(chatManager.groupUnreadCount(for: testGroupID), 2)

        chatManager.markGroupAsRead(groupID: testGroupID)

        XCTAssertEqual(chatManager.groupUnreadCount(for: testGroupID), 0)
    }

    // MARK: - Group Message Status

    func testGroupMessageStatusUpdate() async throws {
        let message = chatManager.saveGroupOutgoing(text: "Test", groupID: testGroupID, localName: "Me")
        XCTAssertEqual(message.status, .sending)

        chatManager.updateGroupMessageStatus(messageID: message.id, status: .delivered)

        if let updated = chatManager.groupMessages.first(where: { $0.id == message.id }) {
            XCTAssertEqual(updated.status, .delivered)
        } else {
            XCTFail("Message not found")
        }
    }

    // MARK: - Total Unread Count

    func testTotalUnreadIncludesGroupUnread() async throws {
        chatManager.activeGroupID = nil

        chatManager.saveGroupIncoming(text: "Group msg", groupID: testGroupID, senderID: "p1", senderName: "Peer")

        XCTAssertGreaterThanOrEqual(chatManager.totalUnread, 1)
    }

    // MARK: - Delete Group Messages

    func testDeleteGroupMessages() async throws {
        chatManager.saveGroupOutgoing(text: "To delete", groupID: testGroupID, localName: "Me")
        XCTAssertEqual(chatManager.groupMessages.count, 1)

        chatManager.deleteGroupMessages(forGroup: testGroupID)

        XCTAssertEqual(chatManager.groupMessages.count, 0)

        // Verify persistence is also cleared
        let newManager = ChatManager()
        newManager.loadGroupMessages(forGroup: testGroupID)
        XCTAssertEqual(newManager.groupMessages.count, 0)
    }

    // MARK: - Load Group Messages

    func testLoadGroupMessagesForNonexistentGroup() async throws {
        let fakeGroupID = "nonexistent-group"
        chatManager.loadGroupMessages(forGroup: fakeGroupID)

        XCTAssertEqual(chatManager.groupMessages.count, 0)
    }

    // MARK: - ChatMessage isGroupMessage Property

    func testIsGroupMessageProperty() async throws {
        let groupMsg = chatManager.saveGroupOutgoing(text: "Group", groupID: testGroupID, localName: "Me")
        XCTAssertTrue(groupMsg.isGroupMessage)

        // Regular message shouldn't be a group message
        let regularMsg = chatManager.saveOutgoing(text: "Regular", peerID: "peer-1", peerName: "Peer")
        XCTAssertFalse(regularMsg.isGroupMessage)
    }
}
