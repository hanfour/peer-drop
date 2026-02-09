import Foundation

/// Payload for emoji reaction on a message.
struct ReactionPayload: Codable {
    enum Action: String, Codable {
        case add
        case remove
    }

    let messageID: String
    let emoji: String
    let action: Action
    let timestamp: Date
}
