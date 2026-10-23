import Foundation
import PeerDropCore
import PeerDropNotes

/// A display-ready row of the 紙條 list.
struct ConversationRowModel: Identifiable, Equatable {
    /// `peer:<record id>` or `group:<group id>` (unique across both kinds).
    let id: String
    /// DeviceRecord.id or DeviceGroup.id.
    let sourceID: String
    let isGroup: Bool
    let name: String
    let summary: ConversationSummary
}

/// Pure list logic for the 紙條 tab (no SwiftUI, unit-testable).
enum ConversationsLogic {
    /// Friends (with a `DeviceRecord`) and groups that have at least one message or note, newest first.
    /// Chat files without a matching record/group are not listed. `query` matches names only.
    static func rows(
        records: [DeviceRecord],
        groups: [DeviceGroup],
        summaryForPeer: (String) -> ConversationSummary,
        summaryForGroup: (String) -> ConversationSummary,
        query: String,
        name: (DeviceRecord) -> String = { $0.displayName }
    ) -> [ConversationRowModel] {
        let needle = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        var result: [ConversationRowModel] = []
        for r in records where matches(name(r), needle) {
            let s = summaryForPeer(r.id)
            guard s.lastMessage != nil || s.lastNote != nil else { continue }
            result.append(ConversationRowModel(id: "peer:\(r.id)", sourceID: r.id, isGroup: false, name: name(r), summary: s))
        }
        for g in groups where matches(g.name, needle) {
            let s = summaryForGroup(g.id)
            guard s.lastMessage != nil else { continue }
            result.append(ConversationRowModel(id: "group:\(g.id)", sourceID: g.id, isGroup: true, name: g.name, summary: s))
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
