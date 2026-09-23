import SwiftUI
import PeerDropDiary

/// Join a diary either by pasting the invite link (spec §3.2, contains the
/// content key) or by typing the short code alone (§3.3 — the diary starts
/// `pendingKey` until a relay arrives). Either field is enough to enable
/// Join; if both are filled the link wins.
struct DiaryJoinSheet: View {
    @ObservedObject var store: DiaryStore
    var onJoined: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var linkText = ""
    @State private var codeText = ""
    @State private var isJoining = false
    @State private var errorMessage: String?

    private var trimmedLink: String { linkText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedCode: String { codeText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canJoin: Bool { !isJoining && !(trimmedLink.isEmpty && trimmedCode.isEmpty) }

    var body: some View {
        Form {
            Section {
                TextField("Paste an invite link", text: $linkText)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
            }
            Section {
                TextField("Short Code", text: $codeText)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    #endif
            } header: { Text("Or enter a short code") }
            if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
        }
        .navigationTitle("Join a Diary")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button { Task { await join() } } label: {
                    if isJoining { ProgressView() } else { Text("Join") }
                }
                .disabled(!canJoin)
            }
        }
    }

    private func join() async {
        isJoining = true; errorMessage = nil
        defer { isJoining = false }
        do {
            let id: String
            if !trimmedLink.isEmpty {
                guard let url = URL(string: trimmedLink) else { throw DiaryError.badId }
                id = try await store.join(link: url)
            } else {
                id = try await store.join(code: trimmedCode.uppercased())
            }
            onJoined(id)
            dismiss()
        } catch let e as DiaryError {
            errorMessage = e.userMessage()
        } catch {
            errorMessage = String(localized: "Something went wrong. Please try again.")
        }
    }
}
