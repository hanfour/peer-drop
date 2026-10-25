import Foundation

/// Wire payload for `MessageType.statusUpdate` (Project F2): the status
/// message of the category the SENDER filed the receiver under. `text == nil`
/// clears it (no category, message hidden, or empty). The receiver drops
/// payloads over 1024 bytes and texts over 60 characters after cleaning.
public struct StatusUpdatePayload: Codable, Equatable {
    public var text: String?
    public var updatedAt: Date

    public init(text: String?, updatedAt: Date) {
        self.text = text
        self.updatedAt = updatedAt
    }
}
