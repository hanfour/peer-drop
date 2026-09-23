import SwiftUI
import PeerDropAccount
import PeerDropNotes
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The Notes tab (iOS) / sidebar section (Mac). Expects an enclosing
/// `NavigationStack(path: $path)`.
struct NotesInboxView: View {
    @ObservedObject var store: NotesStore
    @ObservedObject var accountManager: AccountManager
    /// Set by a notification tap; the view pushes that note and clears it.
    @Binding var openNoteID: String?
    @Binding var path: [NoteRecord]
    @State private var showCompose = false

    var body: some View {
        List {
            if case .ready = accountManager.state {} else {
                AccountSectionView(accountManager: accountManager)
            }
            if store.inbox.isEmpty {
                emptyState
            } else {
                ForEach(store.inbox) { record in
                    NavigationLink(value: record) { NoteRowView(record: record) }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { Task { await store.delete(record) } } label: { Label("Delete Note", systemImage: "trash") }
                        }
                }
            }
        }
        .navigationTitle("Notes")
        .navigationDestination(for: NoteRecord.self) { record in
            NoteDetailView(record: record, store: store)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showCompose = true } label: { Label("New Note", systemImage: "square.and.pencil") }
                    .disabled(accountManager.account == nil)
            }
            ToolbarItem(placement: .secondaryAction) {
                NavigationLink { SentNotesView(store: store) } label: { Label("Sent Notes", systemImage: "paperplane") }
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
