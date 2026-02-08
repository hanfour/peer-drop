import Foundation

struct TextMessagePayload: Codable {
    let text: String
    let timestamp: Date

    // Reply support
    let replyToMessageID: String?
    let replyToText: String?
    let replyToSenderName: String?

    init(text: String, replyToMessageID: String? = nil, replyToText: String? = nil, replyToSenderName: String? = nil) {
        self.text = text
        self.timestamp = Date()
        self.replyToMessageID = replyToMessageID
        self.replyToText = replyToText
        self.replyToSenderName = replyToSenderName
    }

    // Custom decoding for backward compatibility
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        replyToMessageID = try container.decodeIfPresent(String.self, forKey: .replyToMessageID)
        replyToText = try container.decodeIfPresent(String.self, forKey: .replyToText)
        replyToSenderName = try container.decodeIfPresent(String.self, forKey: .replyToSenderName)
    }
}
