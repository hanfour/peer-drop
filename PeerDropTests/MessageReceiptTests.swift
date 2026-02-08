import XCTest
@testable import PeerDrop

/// Tests for message receipt and typing indicator functionality
final class MessageReceiptTests: XCTestCase {

    // MARK: - MessageReceiptPayload Tests

    func testMessageReceiptPayloadEncodeDecode() throws {
        let payload = MessageReceiptPayload(
            messageIDs: ["msg-1", "msg-2", "msg-3"],
            receiptType: .delivered,
            timestamp: Date()
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(payload)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(MessageReceiptPayload.self, from: data)

        XCTAssertEqual(decoded.messageIDs, payload.messageIDs)
        XCTAssertEqual(decoded.receiptType, .delivered)
    }

    func testMessageReceiptPayloadReadType() throws {
        let payload = MessageReceiptPayload(
            messageIDs: ["msg-1"],
            receiptType: .read,
            timestamp: Date()
        )

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(MessageReceiptPayload.self, from: data)

        XCTAssertEqual(decoded.receiptType, .read)
    }

    func testMessageReceiptPayloadEmptyMessageIDs() throws {
        let payload = MessageReceiptPayload(
            messageIDs: [],
            receiptType: .delivered,
            timestamp: Date()
        )

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(MessageReceiptPayload.self, from: data)

        XCTAssertTrue(decoded.messageIDs.isEmpty)
    }

    func testMessageReceiptPayloadBatchMessageIDs() throws {
        let messageIDs = (1...100).map { "msg-\($0)" }
        let payload = MessageReceiptPayload(
            messageIDs: messageIDs,
            receiptType: .read,
            timestamp: Date()
        )

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(MessageReceiptPayload.self, from: data)

        XCTAssertEqual(decoded.messageIDs.count, 100)
        XCTAssertEqual(decoded.messageIDs.first, "msg-1")
        XCTAssertEqual(decoded.messageIDs.last, "msg-100")
    }

    // MARK: - TypingIndicatorPayload Tests

    func testTypingIndicatorPayloadEncodeDecode() throws {
        let payload = TypingIndicatorPayload(
            isTyping: true,
            timestamp: Date()
        )

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(TypingIndicatorPayload.self, from: data)

        XCTAssertTrue(decoded.isTyping)
    }

    func testTypingIndicatorPayloadNotTyping() throws {
        let payload = TypingIndicatorPayload(
            isTyping: false,
            timestamp: Date()
        )

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(TypingIndicatorPayload.self, from: data)

        XCTAssertFalse(decoded.isTyping)
    }

    // MARK: - PeerMessage Factory Tests

    func testPeerMessageReceiptCreation() throws {
        let payload = MessageReceiptPayload(
            messageIDs: ["msg-1"],
            receiptType: .delivered,
            timestamp: Date()
        )

        let message = try PeerMessage.messageReceipt(payload, senderID: "sender-123")

        XCTAssertEqual(message.type, .messageReceipt)
        XCTAssertEqual(message.senderID, "sender-123")
        XCTAssertNotNil(message.payload)

        let decoded = try message.decodePayload(MessageReceiptPayload.self)
        XCTAssertEqual(decoded.messageIDs, ["msg-1"])
        XCTAssertEqual(decoded.receiptType, .delivered)
    }

    func testPeerMessageTypingIndicatorCreation() throws {
        let payload = TypingIndicatorPayload(
            isTyping: true,
            timestamp: Date()
        )

        let message = try PeerMessage.typingIndicator(payload, senderID: "sender-456")

        XCTAssertEqual(message.type, .typingIndicator)
        XCTAssertEqual(message.senderID, "sender-456")
        XCTAssertNotNil(message.payload)

        let decoded = try message.decodePayload(TypingIndicatorPayload.self)
        XCTAssertTrue(decoded.isTyping)
    }

    // MARK: - MessageStatus Tests

    func testMessageStatusReadCase() {
        let status: MessageStatus = .read
        XCTAssertEqual(status.rawValue, "read")
    }

    func testMessageStatusCodable() throws {
        let statuses: [MessageStatus] = [.sending, .sent, .delivered, .read, .failed]

        for status in statuses {
            let data = try JSONEncoder().encode(status)
            let decoded = try JSONDecoder().decode(MessageStatus.self, from: data)
            XCTAssertEqual(decoded, status)
        }
    }
}
