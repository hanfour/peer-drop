import SwiftUI
import PeerDropCore
import PeerDropNotes
import PeerDropAccount

/// Notes tab body: hosts `ConversationsTab` in its own NavigationStack and observes the store
/// so the tab badge updates. This view lives outside the stack, so it keeps running while
/// notes are pushed: it (not the inbox view) resolves `openNoteID` into `pendingNote`.
/// A `.openNote` deep link bumps `inboxRequest`, which makes `ConversationsTab` push the inbox
/// (single route, no-op if already showing); `NotesInboxHost` then pushes `pendingNote`.
struct ConversationsTabContent: View {
    @ObservedObject var store: NotesStore
    @ObservedObject var accountManager: AccountManager
    @Binding var openNoteID: String?
    @Binding var inboxRequest: Int
    var onGoHome: () -> Void
    @State private var pendingNote: NoteRecord?

    var body: some View {
        NavigationStack {
            ConversationsTab(inboxUnread: store.unreadCount, onGoHome: onGoHome, inboxRequest: $inboxRequest) {
                NotesInboxHost(store: store, accountManager: accountManager, note: $pendingNote)
            }
        }
        #if os(iOS)
        .badge(store.unreadCount)
        #endif
        .onChange(of: openNoteID) { _ in resolve() }
        .onChange(of: store.inbox) { _ in resolve() }
        .onAppear { resolve() }
    }

    private func resolve() {
        guard let id = openNoteID, let record = store.note(id: id) else { return }
        openNoteID = nil
        if pendingNote != nil, pendingNote?.id != record.id {
            // A different note is already open: pop it, then push the new one on the next turn.
            pendingNote = nil
            DispatchQueue.main.async { pendingNote = record }
        } else {
            pendingNote = record
        }
    }
}

/// Wraps `NotesInboxView` for use inside ConversationsTab's stack. The stack has no typed
/// `[NoteRecord]` path (it also carries chat targets), so the note to open arrives as `note`
/// and is shown through an `isPresented` destination. Row taps still use the inbox's own
/// value-based links. The destination is armed one turn after appearing so a note that was
/// resolved before the inbox existed still animates in.
struct NotesInboxHost: View {
    @ObservedObject var store: NotesStore
    @ObservedObject var accountManager: AccountManager
    @Binding var note: NoteRecord?
    @State private var armed = false

    var body: some View {
        NotesInboxView(
            store: store,
            accountManager: accountManager,
            openNoteID: .constant(nil),
            path: Binding(get: { note.map { [$0] } ?? [] }, set: { note = $0.last })
        )
        .navigationDestination(isPresented: Binding(get: { armed && note != nil }, set: { if !$0 { note = nil } })) {
            if let record = note { NoteDetailView(record: record, store: store) }
        }
        .onAppear { DispatchQueue.main.async { armed = true } }
    }
}
