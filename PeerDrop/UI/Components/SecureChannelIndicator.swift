import SwiftUI
import PeerDropCore
import PeerDropTransport
import PeerDropSecurity

/// Small chip rendering the `LocalSecureChannel` status next to a peer's
/// name. Observes the `PeerConnection` directly so it updates the instant
/// `secureChannelState` or `pinningVerdict` flips, without depending on
/// the parent view re-rendering. Shared by iOS and Mac targets.
struct SecureChannelIndicator: View {
    @ObservedObject var peerConn: PeerConnection

    var body: some View {
        switch peerConn.secureChannelState {
        case .disabled, .handshakeInProgress:
            // Don't promise encryption while the handshake is still in
            // flight — the channel can still fall back to plaintext.
            EmptyView()
        case .fallbackPlaintext:
            Image(systemName: "lock.open")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Plaintext fallback — peer didn't complete secure handshake")
        case .secured:
            switch peerConn.pinningVerdict {
            case .mismatch:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Encryption key changed — verify peer")
            case .firstTrust:
                Image(systemName: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Encrypted, first-time peer (TOFU)")
            case .matched, .notChecked:
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .accessibilityLabel("Encrypted with verified peer")
            }
        }
    }
}
