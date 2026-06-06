import SwiftUI
import PeerDropCore
import PeerDropTransport  // for DiscoveredPeer

struct MacChatWindow: View {
    let peerID: String
    @EnvironmentObject var connectionManager: ConnectionManager

    var body: some View {
        // Task 6b will replace this stub with iOS ChatView reuse once
        // PhotosUI dependency is gated. Until then, this scaffolding
        // confirms the WindowGroup(for:) scene + openWindow plumbing works.
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text(peerDisplayName)
                .font(.title)
            Text("Chat with \(peerID.prefix(8))…")
                .foregroundStyle(.secondary)
            Text("Chat surface arrives in Task 6b (after ChatView's PhotosUI dependency is gated).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(minWidth: 480, minHeight: 360)
        .navigationTitle(peerDisplayName)
    }

    /// Look up the peer's display name from `discoveredPeers`.
    /// Falls back to a truncated peer ID if no match.
    private var peerDisplayName: String {
        if let peer = connectionManager.discoveredPeers.first(where: { $0.id == peerID }) {
            return peer.displayName
        }
        return String(peerID.prefix(8))
    }
}
