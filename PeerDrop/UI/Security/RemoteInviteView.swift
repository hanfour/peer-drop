import SwiftUI

struct RemoteInviteView: View {
    @ObservedObject var mailboxManager: MailboxManager
    @State private var inviteURL: URL?
    @State private var isGenerating = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "link.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("Remote Invite")
                .font(.title2.bold())

            Text(String(localized: "Generate a link to connect with someone remotely. Share it via any messaging app."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let url = inviteURL {
                VStack(spacing: 12) {
                    Text(url.absoluteString)
                        .font(.system(.caption, design: .monospaced))
                        .padding()
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    ShareLink(item: url) {
                        Label(String(localized: "Share Invite Link"), systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Button(action: generateInvite) {
                    if isGenerating {
                        ProgressView()
                    } else {
                        Label(String(localized: "Generate Invite Link"), systemImage: "link")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isGenerating)
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.green)
                Text(String(localized: "Link contains no secrets. Encryption is established after the recipient accepts."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private func generateInvite() {
        isGenerating = true
        errorMessage = nil
        Task {
            do {
                try await mailboxManager.registerIfNeeded()
                guard let mailboxId = mailboxManager.mailboxId else { return }
                let invite = InvitePayload(
                    mailboxId: mailboxId,
                    identityKeyFingerprint: IdentityKeyManager.shared.fingerprint,
                    displayName: PeerIdentity.local().displayName,
                    expiry: Date().addingTimeInterval(24 * 60 * 60)
                )
                inviteURL = invite.toURL()
            } catch {
                errorMessage = error.localizedDescription
            }
            isGenerating = false
        }
    }
}
