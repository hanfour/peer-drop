import SwiftUI
import PeerDropCore
import PeerDropTransport  // for DiscoveredPeer
import PeerDropPet        // for PetEngine

/// Per-peer chat window hosted by the macOS app's
/// `WindowGroup(id: "chat", for: String.self)` scene.
///
/// M4 follow-up: previously a stub showing placeholder text. Now
/// renders the real cross-platform `ChatView` — Task 1b (#62)
/// cross-platformed ChatView via `Image(platformImage:)` + gated
/// PhotosUI / UIDocumentPicker, so it builds and runs on macOS.
struct MacChatWindow: View {
    let peerID: String
    @EnvironmentObject var connectionManager: ConnectionManager
    @EnvironmentObject var petEngine: PetEngine

    var body: some View {
        // ChatView reads chatManager + peer metadata directly; we look
        // up the friendly display name from discoveredPeers (DeviceRecord
        // store covers trusted peers but the window may open before that
        // hydrates, so fall back to a truncated ID).
        ChatView(
            chatManager: connectionManager.chatManager,
            peerID: peerID,
            peerName: peerDisplayName
        )
        .environmentObject(connectionManager)
        .environmentObject(petEngine)
        .frame(minWidth: 480, minHeight: 480)
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
