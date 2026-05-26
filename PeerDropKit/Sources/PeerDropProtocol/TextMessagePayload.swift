import Foundation

public struct TextMessagePayload: Codable {
    public let text: String
    public let timestamp: Date

    // Reply support
    public let replyToMessageID: String?
    public let replyToText: String?
    public let replyToSenderName: String?

    // Group messaging support
    public let groupID: String?
    public let senderName: String?

    public init(
        text: String,
        replyToMessageID: String? = nil,
        replyToText: String? = nil,
        replyToSenderName: String? = nil,
        groupID: String? = nil,
        senderName: String? = nil
    ) {
        self.text = text
        self.timestamp = Date()
        self.replyToMessageID = replyToMessageID
        self.replyToText = replyToText
        self.replyToSenderName = replyToSenderName
        self.groupID = groupID
        self.senderName = senderName
    }

    // Custom decoding for backward compatibility
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        replyToMessageID = try container.decodeIfPresent(String.self, forKey: .replyToMessageID)
        replyToText = try container.decodeIfPresent(String.self, forKey: .replyToText)
        replyToSenderName = try container.decodeIfPresent(String.self, forKey: .replyToSenderName)
        groupID = try container.decodeIfPresent(String.self, forKey: .groupID)
        senderName = try container.decodeIfPresent(String.self, forKey: .senderName)
    }
}
