import Foundation

struct MessageReceiptPayload: Codable {
    enum ReceiptType: String, Codable {
        case delivered
        case read
    }

    let messageIDs: [String]
    let receiptType: ReceiptType
    let timestamp: Date

    // Group messaging support
    let groupID: String?
    let senderID: String?  // Who is sending this receipt

    init(messageIDs: [String], receiptType: ReceiptType, timestamp: Date, groupID: String? = nil, senderID: String? = nil) {
        self.messageIDs = messageIDs
        self.receiptType = receiptType
        self.timestamp = timestamp
        self.groupID = groupID
        self.senderID = senderID
    }

    // Custom decoding for backward compatibility
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messageIDs = try container.decode([String].self, forKey: .messageIDs)
        receiptType = try container.decode(ReceiptType.self, forKey: .receiptType)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        groupID = try container.decodeIfPresent(String.self, forKey: .groupID)
        senderID = try container.decodeIfPresent(String.self, forKey: .senderID)
    }
}
