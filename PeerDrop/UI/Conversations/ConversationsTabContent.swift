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
    /// Set (to a `DeviceRecord.id`) when a note deep link should open a bound friend's thread.
    @Binding var threadRequest: ThreadRequest?
    var onGoHome: () -> Void
    @EnvironmentObject private var connectionManager: ConnectionManager
    @StateObject private var bound = BoundFriendsModel()
    @State private var pendingNote: NoteRecord?
    /// Local-only 「不接收匿名紙條」: hides anonymous notes on this device, nothing is uploaded.
    @AppStorage(StrangerBox.hideAnonymousKey) private var hideAnonymous = false
    /// Bumped when diary membership changes so the circle is recomputed.
    @State private var diaryRevision = 0

    /// Inbox/tab-badge unread: notes that live in a bound friend's thread are counted on that
    /// friend's row instead (once overall).
    /// Before the model's first refresh, compute synchronously so no unfiltered frame is shown.
    private var boundAccounts: Set<String> {
        bound.isReady ? bound.accounts : Set(BoundFriends.recordIDByAccount(connectionManager).keys)
    }

    /// Friends, diary mates and people I sent a signed note to; everyone else is a stranger.
    private func circle(_ accounts: Set<String>) -> CircleMembership {
        _ = diaryRevision
        return StrangerBox.membership(
            friendAccounts: accounts,
            diaryMemberLists: connectionManager.diaryStore.states.values.map { $0.meta.members },
            sent: store.sent,
            hideAnonymous: hideAnonymous)
    }

    /// Tab badge = friend rows + inbox remainder (strangers included). Hidden anonymous notes count nowhere.
    private func unread(_ accounts: Set<String>, circle: CircleMembership) -> StrangerBox.Unread {
        StrangerBox.unread(store.inbox, boundAccounts: accounts, circle: circle)
    }

    var body: some View {
        let accounts = boundAccounts
        let circle = circle(accounts)
        let counts = unread(accounts, circle: circle)
        return NavigationStack {
            ConversationsTab(inboxUnread: counts.inboxRemainder, onGoHome: onGoHome, inboxRequest: $inboxRequest,
                             threadRequest: $threadRequest,
                             onThreadUnavailable: { id in
                                 if let id, let record = store.note(id: id) { pendingNote = record }
                             }) {
                NotesInboxHost(store: store, accountManager: accountManager, boundAccounts: accounts, circle: circle, note: $pendingNote)
            }
        }
        #if os(iOS)
        .badge(counts.tabBadge)   // TOTAL unread notes, including those that live in friend threads
        #endif
        .onChange(of: openNoteID) { _ in resolve() }
        .onChange(of: store.inbox) { _ in resolve() }
        .onChange(of: store.inbox) { _ in markHiddenOnServer() }
        .onChange(of: hideAnonymous) { _ in markHiddenOnServer() }
        .onReceive(connectionManager.diaryStore.$states) { _ in diaryRevision += 1 }
        .onAppear { bound.bind(connectionManager); resolve(); markHiddenOnServer() }
    }

    /// Hidden anonymous notes are marked read on the server (so they can be evicted first); locally they stay unread.
    private func markHiddenOnServer() {
        let ids = StrangerBox.hiddenIDsToMarkOnServer(store.inbox, circle: circle(boundAccounts))
        guard !ids.isEmpty else { return }
        Task { for id in ids { await store.markReadOnServerOnly(id) } }
    }

    private func resolve() {
        guard let id = openNoteID, let record = store.note(id: id) else { return }
        openNoteID = nil
        // A hidden anonymous note stays hidden, even when its notification is tapped.
        if !StrangerBox.opensFromNotification(record, circle: circle(boundAccounts)) { return }
        // A note from a verified-bound friend belongs to that friend's thread, not the inbox.
        if case .thread(let recordID) = BoundFriends.destination(forNoteID: id, cm: connectionManager) {
            pendingNote = nil
            threadRequest = ThreadRequest(recordID: recordID, noteID: id)
            return
        }
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
    var boundAccounts: Set<String> = []
    var circle = CircleMembership()
    @Binding var note: NoteRecord?
    @State private var armed = false

    var body: some View {
        NotesInboxView(
            store: store,
            accountManager: accountManager,
            openNoteID: .constant(nil),
            boundAccounts: boundAccounts,
            circle: circle,
            path: Binding(get: { note.map { [$0] } ?? [] }, set: { note = $0.last })
        )
        .navigationDestination(isPresented: Binding(get: { armed && note != nil }, set: { if !$0 { note = nil } })) {
            if let record = note { NoteDetailView(record: record, store: store) }
        }
        .onAppear { DispatchQueue.main.async { armed = true } }
    }
}
