import SwiftUI

struct PeerRowView: View {
    let peer: DiscoveredPeer
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                PeerAvatar(name: peer.displayName)

                VStack(alignment: .leading, spacing: 2) {
                    Text(peer.displayName)
                        .font(.body)
                        .foregroundStyle(.primary)

                    Text(sourceLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
        }
    }

    private var sourceLabel: String {
        switch peer.source {
        case .bonjour:
            return "Local Network"
        case .manual:
            return "Manual Connection"
        }
    }
}
