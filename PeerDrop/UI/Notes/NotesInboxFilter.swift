import Foundation
import PeerDropNotes

/// Hides notes that already live in a verified-bound friend's thread so the inbox and the
/// sent list never show the same note twice. Pure: computed from the CURRENT set of bound
/// account ids, so unbinding a friend brings their notes back automatically.
/// Mirrors `NotesStore.notes(forAccount:)` membership (verified inbound sender / non-anonymous
/// outbound recipient).
enum NotesInboxFilter {
    static func isInThread(_ r: NoteRecord, boundAccounts: Set<String>) -> Bool {
        switch r.direction {
        case .inbound:
            guard case .verified(let id, _) = r.sender else { return false }
            return boundAccounts.contains(id)
        case .outbound:
            guard r.sender != .anonymous, let to = r.recipientAccountId else { return false }
            return boundAccounts.contains(to)
        }
    }

    static func inbox(_ notes: [NoteRecord], boundAccounts: Set<String>) -> [NoteRecord] {
        boundAccounts.isEmpty ? notes : notes.filter { !isInThread($0, boundAccounts: boundAccounts) }
    }

    static func sent(_ notes: [NoteRecord], boundAccounts: Set<String>) -> [NoteRecord] {
        inbox(notes, boundAccounts: boundAccounts)
    }
}
