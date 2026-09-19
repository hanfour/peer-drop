import Foundation
import PeerDropNotes

/// Where a `NotesStoreError` surfaced — the generic fallback (`.noAccount`,
/// `.proofOfWorkFailed`, `.network`) reads differently depending on whether
/// the user was trying to send a note or acting on one already in their
/// inbox (block/report/unblock).
enum NotesErrorContext {
    case compose
    case inboxAction
}

extension NotesStoreError {
    /// User-facing text for every case, shared by `ComposeNoteView`,
    /// `NoteDetailView` and `BlockListSection` so the wording stays
    /// consistent (and localized) across all three surfaces.
    func userMessage(context: NotesErrorContext) -> String {
        switch self {
        case .recipientNotFound: return String(localized: "No account found for this ID or nickname.")
        case .recipientHasNoKeys, .opkExhausted: return String(localized: "This person cannot receive notes yet.")
        case .inboxFull: return String(localized: "Their inbox is full. Try again later.")
        case .rateLimited: return String(localized: "Too many notes today. Try again tomorrow.")
        case .textTooLong: return String(localized: "The note is too long.")
        case .noteNotFound: return String(localized: "This note is no longer available.")
        case .noAccount, .proofOfWorkFailed, .network:
            switch context {
            case .compose: return String(localized: "Could not send the note.")
            case .inboxAction: return String(localized: "Something went wrong. Please try again.")
            }
        }
    }
}
