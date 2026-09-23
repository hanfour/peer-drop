import SwiftUI
import PeerDropAccount

struct NicknameEditorView: View {
    @ObservedObject var accountManager: AccountManager
    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @State private var error: LocalizedStringKey?
    @State private var saving = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        Form {
            Section {
                TextField("Nickname", text: $text).autocorrectionDisabled()
                    .focused($fieldFocused)
                    .onSubmit { commitAndSave() }
                    .task(id: text) { error = localError() }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            } footer: { Text("Optional. 3–20 letters, numbers or underscores.") }
        }
        .navigationTitle("Nickname")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { commitAndSave() }.disabled(saving || error != nil) }
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
    /// On macOS a `TextField` is an `NSTextField` whose in-progress edit
    /// only reaches the SwiftUI binding when the field resigns first
    /// responder — and clicking a toolbar button doesn't make it do that.
    /// "Done" therefore used to read the PREVIOUS value of `text` (empty
    /// for a first-time nickname), so the button silently CLEARED the
    /// nickname instead of setting the one on screen — reproduced against
    /// a local worker on 2026-09-15: `PUT /v3/account/nickname` arrived
    /// with `{"nickname":null}`. Dropping focus commits the edit; the
    /// short yield lets that binding update land before `save()` reads it.
    private func commitAndSave() {
        fieldFocused = false
        Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            await save()
        }
    }

    private func save() async {
        saving = true; defer { saving = false }
        do { try await accountManager.setNickname(text.isEmpty ? nil : text); dismiss() }
        catch AccountClientError.conflict("nickname_taken") { error = "This nickname is already taken" }
        catch AccountClientError.rateLimited { error = "Too many changes today. Try again tomorrow." }
        catch AccountManager.NicknameError.reserved { error = "This nickname is reserved" }
        // Registration hasn't completed (or was just deleted): the editor
        // used to dismiss as if the rename had been saved, because
        // setNickname silently returned. Reuse the existing status copy.
        catch AccountManager.AccountManagerError.noAccount { error = "Account not ready" }
        catch let e { error = LocalizedStringKey(String(describing: e)) }
    }
}
