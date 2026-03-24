import XCTest
@testable import PeerDrop

@MainActor
final class MessageEditDeleteTests: XCTestCase {

    // MARK: - Payload Tests

    func testMessageEditPayloadEncoding() throws {
        let payload = MessageEditPayload(messageID: "msg-1", newText: "Updated text")
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(MessageEditPayload.self, from: data)
        XCTAssertEqual(decoded.messageID, "msg-1")
        XCTAssertEqual(decoded.newText, "Updated text")
        XCTAssertNotNil(decoded.editedAt)
        XCTAssertNil(decoded.groupID)
    }

    func testMessageEditPayloadWithGroup() throws {
        let payload = MessageEditPayload(messageID: "msg-1", newText: "Edited", groupID: "group-1")
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(MessageEditPayload.self, from: data)
        XCTAssertEqual(decoded.groupID, "group-1")
    }

    func testMessageDeletePayloadEncoding() throws {
        let payload = MessageDeletePayload(messageID: "msg-2")
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(MessageDeletePayload.self, from: data)
        XCTAssertEqual(decoded.messageID, "msg-2")
        XCTAssertNil(decoded.groupID)
    }

    // MARK: - PeerMessage Factory Tests

    func testMessageEditPeerMessage() throws {
        let payload = MessageEditPayload(messageID: "msg-1", newText: "New")
        let msg = try PeerMessage.messageEdit(payload, senderID: "peer1")
        XCTAssertEqual(msg.type, .messageEdit)
        XCTAssertEqual(msg.senderID, "peer1")
    }

    func testMessageDeletePeerMessage() throws {
        let payload = MessageDeletePayload(messageID: "msg-1")
        let msg = try PeerMessage.messageDelete(payload, senderID: "peer1")
        XCTAssertEqual(msg.type, .messageDelete)
    }

    // MARK: - ChatMessage Edit/Delete Properties

    func testChatMessageDefaultNotEdited() {
        let msg = ChatMessage.text(text: "Hello", isOutgoing: true, peerName: "Test")
        XCTAssertNil(msg.editedAt)
        XCTAssertFalse(msg.isDeleted)
    }

    func testChatMessageCanEditOrDelete() {
        let msg = ChatMessage.text(text: "Hello", isOutgoing: true, peerName: "Test")
        XCTAssertTrue(msg.canEditOrDelete, "Outgoing text message within 5 min should be editable")
    }

    func testChatMessageCannotEditIncoming() {
        let msg = ChatMessage.text(text: "Hello", isOutgoing: false, peerName: "Peer")
        XCTAssertFalse(msg.canEditOrDelete, "Incoming messages should not be editable")
    }

    func testChatMessageCannotEditMedia() {
        let msg = ChatMessage.media(
            mediaType: "image",
            fileName: "photo.jpg",
            fileSize: 1024,
            mimeType: "image/jpeg",
            duration: nil,
            localFileURL: nil,
            thumbnailData: nil,
            isOutgoing: true,
            peerName: "Test"
        )
        XCTAssertFalse(msg.canEditOrDelete, "Media messages should not be editable")
    }

    func testChatMessageCannotEditDeleted() {
        var msg = ChatMessage.text(text: "Hello", isOutgoing: true, peerName: "Test")
        msg.isDeleted = true
        XCTAssertFalse(msg.canEditOrDelete, "Deleted messages should not be editable")
    }

    func testChatMessageCannotEditOldMessage() {
        let oldMsg = ChatMessage(
            id: UUID().uuidString,
            text: "Old",
            isMedia: false,
            mediaType: nil,
            fileName: nil,
            fileSize: nil,
            mimeType: nil,
            duration: nil,
            thumbnailData: nil,
            localFileURL: nil,
            isOutgoing: true,
            peerName: "Test",
            status: .sent,
            timestamp: Date().addingTimeInterval(-600) // 10 min ago
        )
        XCTAssertFalse(oldMsg.canEditOrDelete, "Messages older than 5 min should not be editable")
    }

    // MARK: - ChatMessage Backward Compatibility

    func testChatMessageDecodingWithoutEditFields() throws {
        // Simulate an old message without editedAt/isDeleted
        let json: [String: Any] = [
            "id": "test-1",
            "text": "Hello",
            "isMedia": false,
            "isOutgoing": true,
            "peerName": "Peer",
            "status": "sent",
            "timestamp": Date().timeIntervalSinceReferenceDate
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoder = JSONDecoder()
        let msg = try decoder.decode(ChatMessage.self, from: data)
        XCTAssertNil(msg.editedAt)
        XCTAssertFalse(msg.isDeleted)
    }

    // MARK: - ChatManager Edit/Delete

    func testChatManagerApplyEdit() {
        let chatManager = ChatManager()
        // Create and save a message
        let msg = chatManager.saveOutgoing(text: "Original", peerID: "peer-1", peerName: "Peer")

        // Apply edit
        chatManager.applyEdit(messageID: msg.id, newText: "Edited text", editedAt: Date(), peerID: "peer-1")

        // Verify in-memory update
        if let edited = chatManager.messages.first(where: { $0.id == msg.id }) {
            XCTAssertEqual(edited.text, "Edited text")
            XCTAssertNotNil(edited.editedAt)
        } else {
            XCTFail("Message not found after edit")
        }
    }

    func testChatManagerApplyDelete() {
        let chatManager = ChatManager()
        let msg = chatManager.saveOutgoing(text: "To delete", peerID: "peer-1", peerName: "Peer")

        chatManager.applyDelete(messageID: msg.id, peerID: "peer-1")

        if let deleted = chatManager.messages.first(where: { $0.id == msg.id }) {
            XCTAssertTrue(deleted.isDeleted)
        } else {
            XCTFail("Message not found after delete")
        }
    }
}
