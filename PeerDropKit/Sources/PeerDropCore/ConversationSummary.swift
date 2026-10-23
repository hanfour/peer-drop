import Foundation
import PeerDropNotes

/// Read-only snapshot of one conversation, used by the note list.
public struct ConversationSummary: Identifiable, Equatable {
    public let id: String            // peerID or groupID
    public let isGroup: Bool
    public let lastMessage: ChatMessage?
    /// Newest note of this thread (friend threads only); nil for groups / no notes.
    public let lastNote: NoteRecord?
    public let lastActivity: Date?
    public let unread: Int

    public init(id: String, isGroup: Bool, lastMessage: ChatMessage?, unread: Int) {
        self.init(id: id, isGroup: isGroup, lastMessage: lastMessage, lastNote: nil, unread: unread)
    }

    /// `lastActivity` is the newer of the message timestamp and the note's date
    /// (inbound: receivedAt, outbound: sentAt). `unread` is passed through as given.
    public init(id: String, isGroup: Bool, lastMessage: ChatMessage?, lastNote: NoteRecord?, unread: Int) {
        self.id = id
        self.isGroup = isGroup
        self.lastMessage = lastMessage
        self.lastNote = lastNote
        let noteDate = lastNote.map { $0.direction == .inbound ? $0.receivedAt : $0.sentAt }
        switch (lastMessage?.timestamp, noteDate) {
        case let (m?, n?): self.lastActivity = max(m, n)
        case let (m?, nil): self.lastActivity = m
        case let (nil, n?): self.lastActivity = n
        case (nil, nil): self.lastActivity = nil
        }
        self.unread = unread
    }

    public static func == (lhs: ConversationSummary, rhs: ConversationSummary) -> Bool {
        lhs.id == rhs.id && lhs.isGroup == rhs.isGroup && lhs.unread == rhs.unread
            && lhs.lastMessage?.id == rhs.lastMessage?.id
            && lhs.lastMessage?.isDeleted == rhs.lastMessage?.isDeleted
            && lhs.lastMessage?.text == rhs.lastMessage?.text
            && lhs.lastNote == rhs.lastNote
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

    /// Note preview, prefixed with a mailbox emoji (not localised text itself).
    /// Undecryptable notes yield an empty string.
    public static func text(for note: NoteRecord) -> String {
        guard let t = note.text else { return "" }
        return "📮 " + t
    }
}
