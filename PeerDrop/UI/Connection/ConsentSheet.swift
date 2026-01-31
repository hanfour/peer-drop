import SwiftUI

struct ConsentSheet: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    let request: IncomingRequest

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            PeerAvatar(name: request.peerIdentity.displayName)
                .scaleEffect(1.5)

            VStack(spacing: 8) {
                Text(request.peerIdentity.displayName)
                    .font(.title2.bold())

                Text("wants to connect")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            if let fingerprint = request.peerIdentity.certificateFingerprint {
                VStack(spacing: 4) {
                    Label("Certificate Fingerprint", systemImage: "lock.shield.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(Self.formatFingerprint(fingerprint))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(.horizontal)
            }

            Spacer()

            VStack(spacing: 12) {
                Button {
                    connectionManager.acceptConnection()
                } label: {
                    Text("Accept")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    connectionManager.rejectConnection()
                } label: {
                    Text("Decline")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .presentationDetents([.medium])
    }

    /// Format a hex fingerprint as groups of 4 separated by spaces (e.g. "a1b2 c3d4 e5f6").
    private static func formatFingerprint(_ hex: String) -> String {
        var result = ""
        for (index, char) in hex.enumerated() {
            if index > 0 && index % 4 == 0 { result += " " }
            result.append(char)
        }
        return result
    }
}
