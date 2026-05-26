import Foundation

public struct TypingIndicatorPayload: Codable {
    public let isTyping: Bool
    public let timestamp: Date

    public init(isTyping: Bool, timestamp: Date) {
        self.isTyping = isTyping
        self.timestamp = timestamp
    }
}
