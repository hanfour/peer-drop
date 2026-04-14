import SwiftUI

struct InviteAcceptView: View {
    let invite: InvitePayload
    let connectionManager: ConnectionManager
    let onDismiss: () -> Void

    @State private var isAccepting = false
    @State private var errorMessage: String?
    @State private var accepted = false

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                Image(systemName: "person.badge.shield.checkmark")
                    .font(.system(size: 56))
                    .foregroundStyle(.blue)

                Text(String(localized: "Remote Connection Invite"))
                    .font(.title2.bold())

                VStack(spacing: 8) {
                    Label(invite.displayName, systemImage: "person.fill")
                        .font(.headline)
                    Text(String(localized: "Fingerprint: \(invite.identityKeyFingerprint)"))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                if accepted {
                    Label(String(localized: "Connected securely"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.headline)
                } else if let error = errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }

                Spacer()

                if !accepted {
                    Button(action: acceptInvite) {
                        if isAccepting {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text(String(localized: "Accept & Connect"))
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isAccepting)
                } else {
                    Button(String(localized: "Done")) { onDismiss() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { onDismiss() }
                }
            }
        }
    }

    private func acceptInvite() {
        isAccepting = true
        errorMessage = nil
        Task {
            do {
                try await connectionManager.acceptRemoteInvite(invite)
                accepted = true
            } catch {
                errorMessage = error.localizedDescription
            }
            isAccepting = false
        }
    }
}
