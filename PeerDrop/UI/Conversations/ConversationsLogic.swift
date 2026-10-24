import Foundation
import PeerDropCore

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
    /// Friends (with a `DeviceRecord`) and groups that have at least one message, newest first.
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
            guard s.lastMessage != nil else { continue }
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

    private static func matches(_ name: String, _ needle: String) -> Bool {
        needle.isEmpty || fold(name).contains(needle)
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: nil)
    }
}
