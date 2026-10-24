import Foundation
import PeerDropCore
import PeerDropNotes

/// A display-ready row of the 紙條 list (one per friend; the old device-group chats are retired in F1).
struct ConversationRowModel: Identifiable, Equatable {
    /// `peer:<record id>`.
    let id: String
    /// DeviceRecord.id.
    let sourceID: String
    let name: String
    let summary: ConversationSummary
}

/// Pure list logic for the 紙條 tab (no SwiftUI, unit-testable).
enum ConversationsLogic {
    /// Friends (with a `DeviceRecord`) that have at least one message or note, newest first.
    /// Chat files without a matching record are not listed. `query` matches names only.
    static func rows(
        records: [DeviceRecord],
        summaryForPeer: (String) -> ConversationSummary,
        query: String,
        name: (DeviceRecord) -> String = { $0.displayName }
    ) -> [ConversationRowModel] {
        let needle = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        var result: [ConversationRowModel] = []
        for r in records where matches(name(r), needle) {
            let s = summaryForPeer(r.id)
            guard s.lastMessage != nil || s.lastNote != nil else { continue }
            result.append(ConversationRowModel(id: "peer:\(r.id)", sourceID: r.id, name: name(r), summary: s))
        }
        return result.sorted {
            let a = $0.summary.lastActivity ?? .distantPast
            let b = $1.summary.lastActivity ?? .distantPast
            return a == b ? $0.id < $1.id : a > b
        }
    }

    // MARK: - Notes folding / badge math

    /// Unread remote notes still shown by the inbox row: notes that moved into a friend's thread are
    /// counted by that friend's row instead, so each unread note is counted once overall. Never negative.
    static func inboxUnread(total: Int, boundUnread: Int) -> Int { max(0, total - boundUnread) }

    /// The three unread numbers, kept apart on purpose:
    /// - `tabBadge`: TOTAL unread notes (a bound friend's new note must still raise it)
    /// - `inboxRemainder`: unread shown on the inbox row (total minus notes that live in friend threads)
    /// - `friendRows`: unread notes shown on friend rows; `friendRows + inboxRemainder == tabBadge`
    struct Unread: Equatable { let tabBadge: Int; let inboxRemainder: Int; let friendRows: Int }

    static func unread(total: Int, boundUnread: Int) -> Unread {
        let remainder = inboxUnread(total: total, boundUnread: boundUnread)
        return Unread(tabBadge: total, inboxRemainder: remainder, friendRows: total - remainder)
    }

    /// Per-record summaries with notes folded in. `accountForRecord` holds ONLY records that own their
    /// verified account (one row per account); a record absent from it gets its chat summary untouched.
    static func foldPeers(
        recordIDs: [String],
        chatKey: (String) -> String,
        base: (String) -> ConversationSummary,
        accountForRecord: [String: String],
        notes: (String) -> [NoteRecord],
        noteUnread: (String) -> Int
    ) -> [String: ConversationSummary] {
        var out: [String: ConversationSummary] = [:]
        for id in recordIDs {
            let summary = base(chatKey(id))
            if let account = accountForRecord[id] {
                out[id] = fold(summary, notes: notes(account), noteUnread: noteUnread(account))
            } else {
                out[id] = summary
            }
        }
        return out
    }

    /// Folds a bound friend's notes into the chat summary: the newest note (by `threadDate`, ties by
    /// id) becomes `lastNote`, and the note unread count is added to the chat unread.
    static func fold(_ summary: ConversationSummary, notes: [NoteRecord], noteUnread: Int) -> ConversationSummary {
        guard let newest = notes.max(by: { $0.threadDate != $1.threadDate ? $0.threadDate < $1.threadDate : $0.id < $1.id }) else {
            return summary
        }
        return ConversationSummary(id: summary.id, isGroup: summary.isGroup, lastMessage: summary.lastMessage,
                                   lastNote: newest, unread: summary.unread + noteUnread)
    }

    /// Row preview for a note: mailbox-prefixed text, or a localized placeholder when there is none.
    static func notePreview(_ note: NoteRecord) -> String {
        if (note.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "📮 " + String(localized: "Undecryptable note")
        }
        return ConversationPreview.text(for: note)
    }

    /// One-line row preview: the newer of the last chat message and the last note.
    static func preview(_ s: ConversationSummary) -> String {
        if let n = s.lastNote, n.threadDate >= (s.lastMessage?.timestamp ?? .distantPast) {
            let text = notePreview(n)
            return n.direction == .outbound ? String(format: String(localized: "You: %@"), text) : text
        }
        guard let m = s.lastMessage else { return "" }
        let text = ConversationPreview.text(for: m)
        return m.isOutgoing && !m.isDeleted ? String(format: String(localized: "You: %@"), text) : text
    }

    private static func matches(_ name: String, _ needle: String) -> Bool {
        needle.isEmpty || fold(name).contains(needle)
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: nil)
    }
}
