import SwiftUI
import PeerDropAccount

struct NicknameEditorView: View {
    @ObservedObject var accountManager: AccountManager
    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @State private var error: LocalizedStringKey?
    @State private var saving = false

    var body: some View {
        Form {
            Section {
                TextField("Nickname", text: $text).autocorrectionDisabled()
                    .task(id: text) { error = localError() }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            } footer: { Text("Optional. 3–20 letters, numbers or underscores.") }
        }
        .navigationTitle("Nickname")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { Task { await save() } }.disabled(saving || error != nil) }
            // Lets the Mac sheet presentation (no NavigationStack back
            // button there) be dismissed without saving.
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        }
        .onAppear { text = accountManager.account?.nickname ?? "" }
    }
    private func localError() -> LocalizedStringKey? {
        if text.isEmpty { return nil }
        switch Nickname.validate(text) {
        case .ok: return nil
        case .tooShort: return "Nickname too short"
        case .tooLong: return "Nickname too long"
        case .invalidCharacters: return "Only letters, numbers and underscores"
        case .reserved: return "This nickname is reserved"
        }
    }
    private func save() async {
        saving = true; defer { saving = false }
        do { try await accountManager.setNickname(text.isEmpty ? nil : text); dismiss() }
        catch AccountClientError.conflict("nickname_taken") { error = "This nickname is already taken" }
        catch AccountClientError.rateLimited { error = "Too many changes today. Try again tomorrow." }
        catch AccountManager.NicknameError.reserved { error = "This nickname is reserved" }
        catch let e { error = LocalizedStringKey(String(describing: e)) }
    }
}
