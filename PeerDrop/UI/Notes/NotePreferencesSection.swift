import SwiftUI
import PeerDropAccount
import PeerDropCore

/// Settings rows for notes (shared by iOS Settings and the Mac Profile tab):
/// - 「紙條通知」: global per-account switch, stored on the server (when off, no note pushes at all).
/// - 「不接收匿名紙條」: local-only hide, never uploaded.
struct NotePreferencesSection: View {
    @ObservedObject var accountManager: AccountManager
    @StateObject private var push = NotePushSetting(service: AccountClient(), accountId: nil)
    @AppStorage(StrangerBox.hideAnonymousKey) private var hideAnonymous = false
    @State private var failed = false

    private var pushBinding: Binding<Bool> {
        Binding(get: { push.notePush }, set: { new in Task { await change(new) } })
    }

    var body: some View {
        Group {
            Section {
                Toggle("Note notifications", isOn: pushBinding)
                    .disabled(accountManager.account == nil || push.isUpdating)
                if failed {
                    Text("Couldn't change this setting right now. Please try again later.")
                        .font(.caption).foregroundStyle(.red)
                }
            } header: { Text("Notes") } footer: {
                Text("When this is off, no note will send you a notification. You can still read them in the app.")
            }
            Section {
                Toggle("Don't receive anonymous notes (hidden on this device only)", isOn: $hideAnonymous)
            } footer: {
                Text("This only hides anonymous notes on this device. The sender is not told, and the notes stay stored here, so you can turn this off to see them again. You may still get a notification when one arrives; turn off Note notifications to stop all of them.")
            }
        }
        .task(id: accountManager.account?.accountId.raw) {
            push.useAccount(accountManager.account?.accountId.raw)
            guard accountManager.account != nil, !ScreenshotModeProvider.shared.isActive else { return }
            await push.refresh()
        }
    }

    private func change(_ on: Bool) async {
        failed = false
        await push.set(on)
        failed = push.lastError != nil && push.notePush != on
    }
}
