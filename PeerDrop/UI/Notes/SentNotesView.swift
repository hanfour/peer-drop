import SwiftUI
import PeerDropNotes

struct SentNotesView: View {
    @ObservedObject var store: NotesStore

    var body: some View {
        List {
            if store.sent.isEmpty {
                Text("No sent notes yet.").foregroundStyle(.secondary)
            } else {
                ForEach(store.sent) { record in
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
