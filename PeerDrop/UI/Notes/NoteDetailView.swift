import SwiftUI
import PeerDropNotes

struct NoteDetailView: View {
    let record: NoteRecord
    @ObservedObject var store: NotesStore
    @Environment(\.dismiss) private var dismiss
    @State private var showBlockConfirm = false
    @State private var showReport = false
    @State private var reportReason: ReportReason = .spam
    @State private var includeText = false
    @State private var toast: String?
    @State private var errorMessage: String?

    private var current: NoteRecord { store.note(id: record.id) ?? record }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(senderLine).font(.headline)
                    Spacer()
                    Text(current.sentAt, style: .date).font(.caption).foregroundStyle(.secondary)
                    Text(current.sentAt, style: .time).font(.caption).foregroundStyle(.secondary)
                }
                if let text = current.text {
                    Text(text).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Label("This note could not be decrypted.", systemImage: "lock.slash").foregroundStyle(.secondary)
                }
                if let toast { Text(toast).font(.caption).foregroundStyle(.secondary) }
            }
            .padding()
        }
        .navigationTitle("Note")
        .toolbar {
            ToolbarItem(placement: .destructiveAction) {
                Button(role: .destructive) { Task { await store.delete(current); dismiss() } } label: { Label("Delete Note", systemImage: "trash") }
            }
            if current.direction == .inbound {
                ToolbarItem(placement: .secondaryAction) {
                    Menu {
                        Button(role: .destructive) { showBlockConfirm = true } label: { Label("Block Sender", systemImage: "hand.raised") }
                        Button { showReport = true } label: { Label("Report Note", systemImage: "exclamationmark.bubble") }
                    } label: { Label("More", systemImage: "ellipsis.circle") }
                }
            }
        }
        .task { if current.isUnread { await store.markRead(current.id) } }
        .confirmationDialog("Block this sender?", isPresented: $showBlockConfirm, titleVisibility: .visible) {
            Button("Block Sender", role: .destructive) { Task { await block() } }
        } message: { Text("You will no longer receive notes from this sender, even anonymous ones.") }
        .sheet(isPresented: $showReport) {
            NavigationStack {
                Form {
                    Picker("Report Note", selection: $reportReason) {
                        Text("Spam").tag(ReportReason.spam)
                        Text("Harassment").tag(ReportReason.harassment)
                        Text("Other reason").tag(ReportReason.other)
                    }
                    .pickerStyle(.inline)
                    Toggle("Include the note's text for review", isOn: $includeText).disabled(current.text == nil)
                }
                .navigationTitle("Report Note")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showReport = false } }
                    ToolbarItem(placement: .confirmationAction) { Button("Report Note") { Task { await report() } } }
                }
            }
            #if os(macOS)
            .frame(minWidth: 420, minHeight: 300)
            #endif
        }
        .alert("Note", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var senderLine: String {
        switch current.sender {
        case .anonymous: return current.direction == .outbound ? String(format: String(localized: "Sent to %@"), NoteRowView.display(current.recipientAccountId ?? "")) : String(localized: "Anonymous")
        case .verified(let id, let nick):
            if current.direction == .outbound { return String(format: String(localized: "Sent to %@"), NoteRowView.display(current.recipientAccountId ?? "")) }
            return nick.map { "\($0) · \(NoteRowView.display(id))" } ?? NoteRowView.display(id)
        case .unverified: return String(localized: "Unverified sender")
        }
    }

    private func block() async {
        do { _ = try await store.block(current); toast = String(localized: "Sender blocked") }
        catch { errorMessage = (error as? NotesStoreError)?.userMessage(context: .inboxAction) ?? String(localized: "Something went wrong. Please try again.") }
    }
    private func report() async {
        do { try await store.report(current, reason: reportReason, includeText: includeText); showReport = false; toast = String(localized: "Report sent") }
        catch { showReport = false; errorMessage = (error as? NotesStoreError)?.userMessage(context: .inboxAction) ?? String(localized: "Something went wrong. Please try again.") }
    }
}
