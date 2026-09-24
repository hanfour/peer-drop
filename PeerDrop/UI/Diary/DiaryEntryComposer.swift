import SwiftUI
import PeerDropDiary

/// Write a new page (spec §5.2: "DiaryEntryComposer（5,000 字計數）").
/// Only reachable while `isHolder && hasKey` — `DiaryView` doesn't present
/// this sheet otherwise.
struct DiaryEntryComposer: View {
    let diaryId: String
    @ObservedObject var store: DiaryStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var isPosting = false
    @State private var errorMessage: String?
    @FocusState private var textFocused: Bool

    private var remaining: Int { DiaryCrypto.maxEntryScalars - text.unicodeScalars.count }
    private var canPost: Bool { !isPosting && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && remaining >= 0 }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $text).frame(minHeight: 220).focused($textFocused)
                Text("\(remaining) characters left").font(.caption).foregroundStyle(remaining < 0 ? .red : .secondary)
            }
            if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
        }
        .navigationTitle("New Entry")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button { Task { await post() } } label: {
                    if isPosting { ProgressView() } else { Text("Post") }
                }
                .disabled(!canPost)
            }
        }
        .onAppear { textFocused = true }
    }

    private func post() async {
        isPosting = true; errorMessage = nil
        defer { isPosting = false }
        do {
            try await store.writeEntry(diaryId, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
            dismiss()
        } catch let e as DiaryError {
            errorMessage = e.userMessage()
        } catch {
            errorMessage = String(localized: "Something went wrong. Please try again.")
        }
    }
}
