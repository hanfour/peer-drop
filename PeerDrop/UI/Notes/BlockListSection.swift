import SwiftUI
import PeerDropNotes

/// Settings section: blocked senders (shown by the first 8 chars of their hash).
struct BlockListSection: View {
    @ObservedObject var store: NotesStore
    @State private var blocks: [BlockDTO] = []
    @State private var loaded = false
    @State private var errorMessage: String?

    var body: some View {
        Section {
            if !loaded {
                ProgressView()
            } else if blocks.isEmpty {
                Text("No blocked senders.").foregroundStyle(.secondary)
            } else {
                ForEach(blocks, id: \.senderHash) { b in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(String(b.senderHash.prefix(8))).font(.body.monospaced())
                            Text(Date(timeIntervalSince1970: TimeInterval(b.createdAt) / 1000), style: .date).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Unblock") { Task { await unblock(b.senderHash) } }.buttonStyle(.borderless)
                    }
                }
            }
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red) }
        } header: { Text("Blocked Senders") } footer: {
            Text("Senders are listed by an anonymous code; PeerDrop cannot show who they are.")
        }
        .task { await reload() }
    }

    private func reload() async {
        do { blocks = try await store.blocks(); errorMessage = nil } catch { errorMessage = (error as? NotesStoreError)?.userMessage(context: .inboxAction) ?? String(localized: "Something went wrong. Please try again.") }
        loaded = true
    }
    private func unblock(_ hash: String) async {
        do { try await store.unblock(senderHash: hash); blocks.removeAll { $0.senderHash == hash } } catch { errorMessage = (error as? NotesStoreError)?.userMessage(context: .inboxAction) ?? String(localized: "Something went wrong. Please try again.") }
    }
}
