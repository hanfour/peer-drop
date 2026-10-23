import SwiftUI
import PeerDropTransport
import PeerDropCore

struct PeerGridItemView: View {
    let peer: DiscoveredPeer
    let onTap: () -> Void
    var presence: PeerPresence = .nearby

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                PeerAvatar(name: peer.displayName, size: 60, presence: presence)
                    .accessibilityHidden(true)

                Text(peer.displayName)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(peer.displayName), \(presence.accessibilityLabel)")
        .accessibilityHint("Tap to connect")
    }
}
