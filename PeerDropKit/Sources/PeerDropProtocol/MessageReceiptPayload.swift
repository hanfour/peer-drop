import Foundation

public struct MessageReceiptPayload: Codable {
    public enum ReceiptType: String, Codable {
        case delivered
        case read
    }

    public let messageIDs: [String]
    public let receiptType: ReceiptType
    public let timestamp: Date

    // Group messaging support
    public let groupID: String?
    public let senderID: String?  // Who is sending this receipt

    public init(messageIDs: [String], receiptType: ReceiptType, timestamp: Date, groupID: String? = nil, senderID: String? = nil) {
        self.messageIDs = messageIDs
        self.receiptType = receiptType
        self.timestamp = timestamp
        self.groupID = groupID
        self.senderID = senderID
    }

    // Custom decoding for backward compatibility
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messageIDs = try container.decode([String].self, forKey: .messageIDs)
        receiptType = try container.decode(ReceiptType.self, forKey: .receiptType)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        groupID = try container.decodeIfPresent(String.self, forKey: .groupID)
        senderID = try container.decodeIfPresent(String.self, forKey: .senderID)
    }
}
