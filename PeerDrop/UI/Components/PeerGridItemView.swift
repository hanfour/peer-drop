import SwiftUI

struct PeerGridItemView: View {
    let peer: DiscoveredPeer
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                PeerAvatar(name: peer.displayName)
                    .scaleEffect(1.5)
                    .frame(width: 60, height: 60)

                Text(peer.displayName)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(peer.displayName)
        .accessibilityHint("Tap to connect")
    }
}
