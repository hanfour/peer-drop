import SwiftUI
import PeerDropAccount

#if os(iOS)
struct OnboardingAccountPage: View {
    @ObservedObject var accountManager: AccountManager
    @State private var nickname = ""
    @State private var nicknameError: LocalizedStringKey?

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "person.text.rectangle").font(.system(size: 60)).foregroundStyle(.white)
            Text("Your PeerDrop ID").font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(.white)
            switch accountManager.state {
            case .ready(let account):
                Text(account.accountId.display).font(.system(size: 34, weight: .semibold, design: .monospaced)).foregroundStyle(.white)
                Text("Friends can send you notes with this ID or your nickname.").font(.body).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center).padding(.horizontal, 40)
                TextField("Nickname", text: $nickname).textFieldStyle(.roundedBorder).padding(.horizontal, 40)
                    .onSubmit { Task { await saveNickname() } }
                if let nicknameError { Text(nicknameError).font(.caption).foregroundStyle(.yellow) }
            case .registering, .idle:
                ProgressView().tint(.white); Text("Setting up your account…").foregroundStyle(.white.opacity(0.8))
            case .unavailable(.attestUnsupported):
                Text("This Mac can't create an account (no Secure Enclave). Nearby sharing still works.").foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center).padding(.horizontal, 40)
            case .unavailable:
                Text("Account not ready").foregroundStyle(.white)
                Button("Retry") { Task { await accountManager.registerIfNeeded() } }.foregroundStyle(.white)
            }
            Spacer(); Spacer()
        }
        .task { await accountManager.bootstrap() }
    }
    private func saveNickname() async {
        guard !nickname.isEmpty else { return }
        do { try await accountManager.setNickname(nickname); nicknameError = nil }
        catch AccountClientError.conflict("nickname_taken") { nicknameError = "This nickname is already taken" }
        catch { nicknameError = "Only letters, numbers and underscores" }
    }
}
#else
// Onboarding is iOS-only (see OnboardingView.swift); this stub keeps the
// file compiling cross-platform for the Mac target, which never presents it.
struct OnboardingAccountPage: View {
    var body: some View { EmptyView() }
}
#endif
