import SwiftUI
import PeerDropAccount
import PeerDropNotes
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The notes inbox. Mac: sidebar section inside `NavigationStack(path: $path)`.
/// iOS: pushed from the Notes tab's first row (via `NotesInboxHost`, which bridges
/// the programmatic `path` write to a pushed `NoteDetailView`).
struct NotesInboxView: View {
    @ObservedObject var store: NotesStore
    @ObservedObject var accountManager: AccountManager
    /// Set by a notification tap; the view pushes that note and clears it.
    @Binding var openNoteID: String?
    /// Verified-bound friends' accounts: their notes live in the thread, not here.
    var boundAccounts: Set<String> = []
    /// Who counts as "in my circle"; everyone else lands in the 陌生人 section (local only).
    var circle = CircleMembership()
    @Binding var path: [NoteRecord]
    @State private var showCompose = false

    var body: some View {
        List {
            if case .ready = accountManager.state {} else {
                AccountSectionView(accountManager: accountManager)
            }
            let parts = StrangerBox.partition(store.inbox, boundAccounts: boundAccounts, circle: circle)
            if parts.circle.isEmpty && parts.strangers.isEmpty {
                emptyState
            } else {
                ForEach(parts.circle) { record in noteLink(record) }
            }
            if !parts.strangers.isEmpty {
                strangersSection(parts.strangers)
            }
        }
        .navigationTitle("Notes")
        .navigationDestination(for: NoteRecord.self) { record in
            NoteDetailView(record: record, store: store, readIsLocalOnly: StrangerBox.readIsLocalOnly(record, circle: circle))
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showCompose = true } label: { Label("New Note", systemImage: "square.and.pencil") }
                    .disabled(accountManager.account == nil)
            }
            ToolbarItem(placement: .secondaryAction) {
                NavigationLink { SentNotesView(store: store, boundAccounts: boundAccounts) } label: { Label("Sent Notes", systemImage: "paperplane") }
            }
        }
        .refreshable { await store.sync() }
        .sheet(isPresented: $showCompose) {
            NavigationStack { ComposeNoteView(store: store) }
                #if os(macOS)
                .frame(minWidth: 480, minHeight: 360)
                #endif
        }
        .task { await store.sync() }
        .onChange(of: openNoteID) { _ in openPendingNote() }
        .onChange(of: store.inbox) { _ in openPendingNote() }
        .onAppear { openPendingNote() }
    }

    private func noteLink(_ record: NoteRecord) -> some View {
        NavigationLink(value: record) { NoteRowView(record: record) }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { Task { await store.delete(record) } } label: { Label("Delete Note", systemImage: "trash") }
            }
    }

    /// 陌生人: notes from people outside the circle. Local only: opening one sends nothing, and nobody is told.
    private func strangersSection(_ notes: [NoteRecord]) -> some View {
        let unread = notes.filter(\.isUnread).count
        return Section {
            ForEach(notes) { record in noteLink(record) }
        } header: {
            Text(unread > 0 ? String(format: String(localized: "Strangers (%lld unread)"), unread) : String(localized: "Strangers"))
        } footer: {
            Text("Notes from people you haven't connected with. Reading them is private to this device. The sender is never told.")
        }
    }

    private func openPendingNote() {
        guard let id = openNoteID, let record = store.note(id: id) else { return }
        path = [record]
        openNoteID = nil
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No notes yet. Share your ID with a friend.").foregroundStyle(.secondary)
            if let account = accountManager.account {
                Button("Copy ID") { copy(account.accountId.display) }.buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 8)
    }

    // Same platform-guarded pasteboard code as AccountSectionView.copy(_:).
    private func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
