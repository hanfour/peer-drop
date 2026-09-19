import SwiftUI
import PeerDropNotes

struct ComposeNoteView: View {
    @ObservedObject var store: NotesStore
    @Environment(\.dismiss) private var dismiss
    @State private var handle = ""
    @State private var text = ""
    @State private var anonymous = false
    @State private var isSending = false
    @State private var errorMessage: String?
    @FocusState private var textFocused: Bool

    private var remaining: Int { NoteCrypto.maxTextScalars - text.unicodeScalars.count }
    private var canSend: Bool { !isSending && !handle.trimmingCharacters(in: .whitespaces).isEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && remaining >= 0 }

    var body: some View {
        Form {
            Section("Recipient") {
                TextField("Enter an ID or nickname", text: $handle)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
            }
            Section {
                TextEditor(text: $text).frame(minHeight: 140).focused($textFocused)
                Text("\(remaining) characters left").font(.caption).foregroundStyle(remaining < 0 ? .red : .secondary)
            }
            Section {
                Toggle("Send anonymously", isOn: $anonymous)
                if anonymous { Text("The recipient will not see your ID.").font(.caption).foregroundStyle(.secondary) }
            }
            if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
        }
        .navigationTitle("New Note")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button { Task { await send() } } label: {
                    if isSending { HStack { ProgressView(); Text("Sending...") } } else { Text("Send") }
                }
                .disabled(!canSend)
            }
        }
        .onAppear { textFocused = true }
    }

    private func send() async {
        isSending = true; errorMessage = nil
        defer { isSending = false }
        do {
            _ = try await store.send(text: text.trimmingCharacters(in: .whitespacesAndNewlines), to: handle.trimmingCharacters(in: .whitespaces), anonymous: anonymous)
            dismiss()
        } catch let e as NotesStoreError {
            errorMessage = Self.message(for: e)
        } catch {
            errorMessage = String(localized: "Could not send the note.")
        }
    }

    static func message(for error: NotesStoreError) -> String {
        switch error {
        case .recipientNotFound: return String(localized: "No account found for this ID or nickname.")
        case .recipientHasNoKeys, .opkExhausted: return String(localized: "This person cannot receive notes yet.")
        case .inboxFull: return String(localized: "Their inbox is full. Try again later.")
        case .rateLimited: return String(localized: "Too many notes today. Try again tomorrow.")
        case .textTooLong: return String(format: String(localized: "%lld characters left"), 0)
        case .noAccount, .proofOfWorkFailed, .network: return String(localized: "Could not send the note.")
        }
    }
}
