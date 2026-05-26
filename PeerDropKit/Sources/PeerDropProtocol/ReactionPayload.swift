import Foundation

/// Payload for emoji reaction on a message.
public struct ReactionPayload: Codable {
    public enum Action: String, Codable {
        case add
        case remove
    }

    public let messageID: String
    public let emoji: String
    public let action: Action
    public let timestamp: Date

    public init(messageID: String, emoji: String, action: Action, timestamp: Date) {
        self.messageID = messageID
        self.emoji = emoji
        self.action = action
        self.timestamp = timestamp
    }
}
