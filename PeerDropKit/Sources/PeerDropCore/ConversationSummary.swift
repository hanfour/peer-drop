import Foundation

/// Read-only snapshot of one conversation, used by the note list.
public struct ConversationSummary: Identifiable, Equatable {
    public let id: String            // peerID or groupID
    public let isGroup: Bool
    public let lastMessage: ChatMessage?
    public let lastActivity: Date?
    public let unread: Int

    public init(id: String, isGroup: Bool, lastMessage: ChatMessage?, unread: Int) {
        self.id = id
        self.isGroup = isGroup
        self.lastMessage = lastMessage
        self.lastActivity = lastMessage?.timestamp
        self.unread = unread
    }

    public static func == (lhs: ConversationSummary, rhs: ConversationSummary) -> Bool {
        lhs.id == rhs.id && lhs.isGroup == rhs.isGroup && lhs.unread == rhs.unread
            && lhs.lastMessage?.id == rhs.lastMessage?.id
            && lhs.lastMessage?.isDeleted == rhs.lastMessage?.isDeleted
            && lhs.lastMessage?.text == rhs.lastMessage?.text
            && lhs.lastActivity == rhs.lastActivity
    }
}

/// One-line, localized preview text for a conversation's last message.
public enum ConversationPreview {
    public static func text(for message: ChatMessage) -> String {
        if message.isDeleted { return String(localized: "Message deleted") }
        if message.isMedia {
            switch message.mediaType {
            case "image": return String(localized: "📷 Photo")
            case "video": return String(localized: "🎞 Video")
            case "voice": return String(localized: "🎙 Voice message")
            case "file":
                if let name = message.fileName, !name.isEmpty {
                    return String(localized: "📄 \(name)")
                }
                return String(localized: "Attachment")
            default: return String(localized: "Attachment")
            }
        }
        return message.text ?? ""
    }
}
