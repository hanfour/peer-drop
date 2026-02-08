import XCTest
@testable import PeerDrop

/// Tests for message reply functionality
final class MessageReplyTests: XCTestCase {

    // MARK: - TextMessagePayload Reply Tests

    func testTextMessagePayloadWithReply() throws {
        let payload = TextMessagePayload(
            text: "This is a reply",
            replyToMessageID: "original-msg-123",
            replyToText: "Original message text",
            replyToSenderName: "Alice"
        )

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(TextMessagePayload.self, from: data)

        XCTAssertEqual(decoded.text, "This is a reply")
        XCTAssertEqual(decoded.replyToMessageID, "original-msg-123")
        XCTAssertEqual(decoded.replyToText, "Original message text")
        XCTAssertEqual(decoded.replyToSenderName, "Alice")
    }

    func testTextMessagePayloadWithoutReply() throws {
        let payload = TextMessagePayload(text: "Just a normal message")

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(TextMessagePayload.self, from: data)

        XCTAssertEqual(decoded.text, "Just a normal message")
        XCTAssertNil(decoded.replyToMessageID)
        XCTAssertNil(decoded.replyToText)
        XCTAssertNil(decoded.replyToSenderName)
    }

    func testTextMessagePayloadPartialReplyInfo() throws {
        // Reply to own message (no sender name)
        let payload = TextMessagePayload(
            text: "Replying to myself",
            replyToMessageID: "my-msg-456",
            replyToText: "My original message",
            replyToSenderName: nil
        )

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(TextMessagePayload.self, from: data)

        XCTAssertEqual(decoded.replyToMessageID, "my-msg-456")
        XCTAssertEqual(decoded.replyToText, "My original message")
        XCTAssertNil(decoded.replyToSenderName)
    }

    func testTextMessagePayloadBackwardCompatibility() throws {
        // Simulate a payload from an older version without reply fields
        let legacyJSON = """
        {
            "text": "Legacy message",
            "timestamp": 1707436800
        }
        """
        let data = legacyJSON.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(TextMessagePayload.self, from: data)

        XCTAssertEqual(decoded.text, "Legacy message")
        XCTAssertNil(decoded.replyToMessageID)
        XCTAssertNil(decoded.replyToText)
        XCTAssertNil(decoded.replyToSenderName)
    }

    // MARK: - ChatMessage Reply Tests

    func testChatMessageIsReplyProperty() {
        let replyMessage = ChatMessage(
            id: "msg-1",
            text: "Reply text",
            isMedia: false,
            mediaType: nil,
            fileName: nil,
            fileSize: nil,
            mimeType: nil,
            duration: nil,
            thumbnailData: nil,
            localFileURL: nil,
            isOutgoing: true,
            peerName: "Bob",
            status: .sent,
            timestamp: Date(),
            replyToMessageID: "original-123",
            replyToText: "Original text",
            replyToSenderName: "Alice"
        )

        XCTAssertTrue(replyMessage.isReply)
        XCTAssertEqual(replyMessage.replyToMessageID, "original-123")
        XCTAssertEqual(replyMessage.replyToText, "Original text")
        XCTAssertEqual(replyMessage.replyToSenderName, "Alice")
    }

    func testChatMessageNotReply() {
        let normalMessage = ChatMessage(
            id: "msg-2",
            text: "Normal message",
            isMedia: false,
            mediaType: nil,
            fileName: nil,
            fileSize: nil,
            mimeType: nil,
            duration: nil,
            thumbnailData: nil,
            localFileURL: nil,
            isOutgoing: false,
            peerName: "Alice",
            status: .delivered,
            timestamp: Date(),
            replyToMessageID: nil,
            replyToText: nil,
            replyToSenderName: nil
        )

        XCTAssertFalse(normalMessage.isReply)
    }

    func testChatMessageTextWithReplyFactory() {
        let originalMessage = ChatMessage(
            id: "original-msg",
            text: "This is the original",
            isMedia: false,
            mediaType: nil,
            fileName: nil,
            fileSize: nil,
            mimeType: nil,
            duration: nil,
            thumbnailData: nil,
            localFileURL: nil,
            isOutgoing: false,
            peerName: "Bob",
            status: .delivered,
            timestamp: Date(),
            replyToMessageID: nil,
            replyToText: nil,
            replyToSenderName: nil
        )

        let replyMessage = ChatMessage.text(
            text: "This is my reply",
            isOutgoing: true,
            peerName: "Me",
            replyTo: originalMessage
        )

        XCTAssertTrue(replyMessage.isReply)
        XCTAssertEqual(replyMessage.replyToMessageID, "original-msg")
        XCTAssertEqual(replyMessage.replyToText, "This is the original")
        XCTAssertEqual(replyMessage.replyToSenderName, "Bob")
    }

    func testChatMessageReplyToMediaMessage() {
        let mediaMessage = ChatMessage(
            id: "media-msg",
            text: nil,
            isMedia: true,
            mediaType: "image",
            fileName: "photo.jpg",
            fileSize: 12345,
            mimeType: "image/jpeg",
            duration: nil,
            thumbnailData: nil,
            localFileURL: "path/to/photo.jpg",
            isOutgoing: false,
            peerName: "Alice",
            status: .delivered,
            timestamp: Date(),
            replyToMessageID: nil,
            replyToText: nil,
            replyToSenderName: nil
        )

        let replyMessage = ChatMessage.text(
            text: "Nice photo!",
            isOutgoing: true,
            peerName: "Me",
            replyTo: mediaMessage
        )

        XCTAssertTrue(replyMessage.isReply)
        XCTAssertEqual(replyMessage.replyToMessageID, "media-msg")
        // For media messages, the reply text should be the filename
        XCTAssertEqual(replyMessage.replyToText, "photo.jpg")
        XCTAssertEqual(replyMessage.replyToSenderName, "Alice")
    }

    func testChatMessageReplyToOwnMessage() {
        let ownMessage = ChatMessage(
            id: "own-msg",
            text: "My original message",
            isMedia: false,
            mediaType: nil,
            fileName: nil,
            fileSize: nil,
            mimeType: nil,
            duration: nil,
            thumbnailData: nil,
            localFileURL: nil,
            isOutgoing: true,
            peerName: "Me",
            status: .sent,
            timestamp: Date(),
            replyToMessageID: nil,
            replyToText: nil,
            replyToSenderName: nil
        )

        let replyMessage = ChatMessage.text(
            text: "Replying to myself",
            isOutgoing: true,
            peerName: "Me",
            replyTo: ownMessage
        )

        XCTAssertTrue(replyMessage.isReply)
        XCTAssertEqual(replyMessage.replyToMessageID, "own-msg")
        XCTAssertEqual(replyMessage.replyToText, "My original message")
        // For outgoing messages, sender name should be nil (will display as "You" in UI)
        XCTAssertNil(replyMessage.replyToSenderName)
    }

    // MARK: - ChatMessage Codable Tests

    func testChatMessageWithReplyCodable() throws {
        let message = ChatMessage(
            id: "msg-1",
            text: "Reply text",
            isMedia: false,
            mediaType: nil,
            fileName: nil,
            fileSize: nil,
            mimeType: nil,
            duration: nil,
            thumbnailData: nil,
            localFileURL: nil,
            isOutgoing: true,
            peerName: "Bob",
            status: .sent,
            timestamp: Date(),
            replyToMessageID: "original-123",
            replyToText: "Original text",
            replyToSenderName: "Alice"
        )

        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)

        XCTAssertEqual(decoded.id, message.id)
        XCTAssertEqual(decoded.text, message.text)
        XCTAssertTrue(decoded.isReply)
        XCTAssertEqual(decoded.replyToMessageID, "original-123")
        XCTAssertEqual(decoded.replyToText, "Original text")
        XCTAssertEqual(decoded.replyToSenderName, "Alice")
    }

    func testChatMessageWithoutReplyCodableBackwardCompatibility() throws {
        // Simulate a message from storage without reply fields
        let legacyJSON = """
        {
            "id": "legacy-msg",
            "text": "Old message",
            "isMedia": false,
            "isOutgoing": true,
            "peerName": "Bob",
            "status": "sent",
            "timestamp": 1707436800
        }
        """
        let data = legacyJSON.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(ChatMessage.self, from: data)

        XCTAssertEqual(decoded.id, "legacy-msg")
        XCTAssertEqual(decoded.text, "Old message")
        XCTAssertFalse(decoded.isReply)
        XCTAssertNil(decoded.replyToMessageID)
        XCTAssertNil(decoded.replyToText)
        XCTAssertNil(decoded.replyToSenderName)
    }

    // MARK: - PeerMessage with Reply Tests

    func testPeerMessageTextMessageWithReply() throws {
        let payload = TextMessagePayload(
            text: "Reply message",
            replyToMessageID: "orig-123",
            replyToText: "Original",
            replyToSenderName: "Sender"
        )

        let message = try PeerMessage.textMessage(payload, senderID: "sender-id")

        XCTAssertEqual(message.type, .textMessage)
        XCTAssertNotNil(message.payload)

        let decoded = try message.decodePayload(TextMessagePayload.self)
        XCTAssertEqual(decoded.text, "Reply message")
        XCTAssertEqual(decoded.replyToMessageID, "orig-123")
        XCTAssertEqual(decoded.replyToText, "Original")
        XCTAssertEqual(decoded.replyToSenderName, "Sender")
    }

    // MARK: - Edge Cases

    func testReplyToLongText() throws {
        let longText = String(repeating: "A", count: 1000)
        let payload = TextMessagePayload(
            text: "Reply to long message",
            replyToMessageID: "long-msg",
            replyToText: longText,
            replyToSenderName: "Alice"
        )

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(TextMessagePayload.self, from: data)

        XCTAssertEqual(decoded.replyToText, longText)
        XCTAssertEqual(decoded.replyToText?.count, 1000)
    }

    func testReplyWithSpecialCharacters() throws {
        let specialText = "Hello! 你好 🎉 \"quotes\" & <tags>"
        let payload = TextMessagePayload(
            text: "Reply",
            replyToMessageID: "special-msg",
            replyToText: specialText,
            replyToSenderName: "使用者 🙂"
        )

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(TextMessagePayload.self, from: data)

        XCTAssertEqual(decoded.replyToText, specialText)
        XCTAssertEqual(decoded.replyToSenderName, "使用者 🙂")
    }
}
