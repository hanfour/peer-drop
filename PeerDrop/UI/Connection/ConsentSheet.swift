import SwiftUI

struct ConsentSheet: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    let request: IncomingRequest

    var body: some View {
        PeerActionSheet(
            peerName: request.peerIdentity.displayName,
            subtitle: "wants to connect",
            primaryLabel: "Accept",
            secondaryLabel: "Decline",
            secondaryColor: .red,
            onPrimary: { connectionManager.acceptConnection() },
            onSecondary: { connectionManager.rejectConnection() }
        ) {
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
        }
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
