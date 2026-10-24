import Foundation
import PeerDropNotes

/// One entry of a friend thread: a chat message, a stored note, or a note still
/// waiting in the outbox. Sorted by `date`.
public enum ThreadItem: Identifiable, Equatable {
    case chat(ChatMessage)
    case note(NoteRecord)
    case queued(NoteOutboxEntry)

    public var id: String {
        switch self {
        case .chat(let m): return "chat:\(m.id)"
        case .note(let n): return "note:\(n.id)"
        case .queued(let q): return "queued:\(q.id.uuidString)"
        }
    }

    public static func == (lhs: ThreadItem, rhs: ThreadItem) -> Bool {
        switch (lhs, rhs) {
        case let (.chat(a), .chat(b)):
            return a.id == b.id && a.text == b.text && a.isDeleted == b.isDeleted && a.timestamp == b.timestamp
                && a.status == b.status && a.editedAt == b.editedAt && a.reactions == b.reactions
        case let (.note(a), .note(b)): return a == b
        case let (.queued(a), .queued(b)): return a == b
        default: return false
        }
    }

    /// chat: timestamp; inbound note: receivedAt (robust to sender clock skew);
    /// outbound note: sentAt; queued: createdAt.
    public var date: Date {
        switch self {
        case .chat(let m): return m.timestamp
        case .note(let n): return n.threadDate
        case .queued(let q): return q.createdAt
        }
    }

    public var isOutgoing: Bool {
        switch self {
        case .chat(let m): return m.isOutgoing
        case .note(let n): return n.direction == .outbound
        case .queued: return true
        }
    }

    /// Run-grouping key; same scheme as `ChatMessageRuns` for chat.
    var senderKey: String {
        switch self {
        case .chat(let m): return ChatMessageRuns.speakerKey(m)
        case .note, .queued: return isOutgoing ? "\u{0}me" : "\u{0}peer"
        }
    }
}

public enum ThreadMerge {
    /// Ascending by `date`, ties broken by `id`; duplicate ids collapsed (first wins).
    /// While older chat pages remain (`hasMoreChat`), notes/queued older than
    /// `oldestLoadedChatDate` are held back so they don't appear above chat that
    /// hasn't loaded yet; with no anchor (`nil`, i.e. no chat loaded) everything is included.
    /// A queued entry whose `sentNoteID` matches a note in `notes` is the already-delivered
    /// twin of that note (the entry is removed just after the send) and is dropped, so the
    /// thread never shows both. A queued bubble turning into a sent note may move position
    /// (sentAt is the real send time); that jump is accepted.
    public static func items(
        chat: [ChatMessage], notes: [NoteRecord], queued: [NoteOutboxEntry],
        oldestLoadedChatDate: Date?, hasMoreChat: Bool
    ) -> [ThreadItem] {
        var all = chat.map(ThreadItem.chat)
        let noteIDs = Set(notes.map(\.id))
        let liveQueued = queued.filter { $0.sentNoteID.map { !noteIDs.contains($0) } ?? true }
        var extra = notes.map(ThreadItem.note) + liveQueued.map(ThreadItem.queued)
        if hasMoreChat, let oldest = oldestLoadedChatDate {
            extra = extra.filter { $0.date >= oldest }
        }
        all += extra
        var seen = Set<String>()
        all = all.filter { seen.insert($0.id).inserted }
        return all.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
    }

    public static func runStartIDs(
        in items: [ThreadItem], gap: TimeInterval = ChatMessageRuns.defaultGap, calendar: Calendar = .current
    ) -> Set<String> {
        ChatMessageRuns.runStarts(items, id: \.id, speaker: \.senderKey, date: \.date, gap: gap, calendar: calendar)
    }

    public static func dayStartIDs(in items: [ThreadItem], calendar: Calendar = .current) -> Set<String> {
        ChatMessageRuns.dayStarts(items, id: \.id, date: \.date, calendar: calendar)
    }
}
