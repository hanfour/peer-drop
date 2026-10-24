import SwiftUI
import PeerDropNotes

struct SentNotesView: View {
    @ObservedObject var store: NotesStore
    var boundAccounts: Set<String> = []

    var body: some View {
        List {
            let visible = NotesInboxFilter.sent(store.sent, boundAccounts: boundAccounts)
            if visible.isEmpty {
                Text("No sent notes yet.").foregroundStyle(.secondary)
            } else {
                ForEach(visible) { record in
                    NavigationLink(value: record) { NoteRowView(record: record) }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { Task { await store.delete(record) } } label: { Label("Delete Note", systemImage: "trash") }
                        }
                }
            }
        }
        .navigationTitle("Sent Notes")
    }
}
