import SwiftUI
import PeerDropAccount
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Account rows shared by iOS Settings and Mac Profile tab (platform imports guarded; lint only scans PeerDropKit/Sources).
struct AccountSectionView: View {
    @ObservedObject var accountManager: AccountManager
    @State private var copied = false
    @State private var showDeleteConfirm = false
    @State private var deleteError: String?

    var body: some View {
        Section {
            switch accountManager.state {
            case .ready(let account):
                LabeledContent("Your PeerDrop ID") {
                    HStack(spacing: 8) {
                        Text(account.accountId.display).font(.body.monospaced()).textSelection(.enabled)
                        Button(copied ? "Copied" : "Copy ID") { copy(account.accountId.display) }.buttonStyle(.borderless)
                    }
                }
                NavigationLink { NicknameEditorView(accountManager: accountManager) } label: {
                    LabeledContent("Nickname", value: account.nickname ?? "—")
                }
                Button(role: .destructive) { showDeleteConfirm = true } label: { Text("Delete Account") }
            case .registering, .idle:
                HStack { ProgressView(); Text("Setting up your account…") }
            case .unavailable(let reason):
                VStack(alignment: .leading, spacing: 6) {
                    Text("Account not ready").font(.headline)
                    Text(message(for: reason)).font(.caption).foregroundStyle(.secondary)
                    if reason != .attestUnsupported {
                        Button("Retry") { Task { await accountManager.registerIfNeeded() } }
                    }
                }
            }
        } header: { Text("Account") } footer: {
            Text("Changing devices creates a new account. There is no account recovery yet.")
        }
        .confirmationDialog("Delete your account?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete Account", role: .destructive) { Task { await delete() } }
        } message: { Text("Your ID and nickname will be released. Notes and diaries tied to this account will be lost. Nearby sharing keeps working.") }
        .alert("Account not ready", isPresented: .constant(deleteError != nil)) { Button("OK") { deleteError = nil } } message: { Text(deleteError ?? "") }
    }

    private func message(for reason: AccountManager.Unavailable) -> LocalizedStringKey {
        switch reason {
        case .attestUnsupported: return "This Mac can't create an account (no Secure Enclave). Nearby sharing still works."
        case .offline: return "You're offline. We'll retry automatically."
        case .failed(let s): return LocalizedStringKey(s)
        }
    }
    private func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        #endif
        copied = true
        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
    }
    private func delete() async {
        do { try await accountManager.deleteAccount(); await accountManager.registerIfNeeded() }
        catch { deleteError = String(describing: error) }
    }
}
