import SwiftUI
import PeerDropCore
import PeerDropTransport  // for DiscoveredPeer

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
    @State private var toastMessage: String?

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
        .frame(minWidth: 480, minHeight: 480)
        .background(PaperTheme.color(.background))
        .navigationTitle(peerDisplayName)
        // ConnectionManager.statusToast is only rendered by the iOS ContentView, so
        // on macOS chat errors (voice failure, file too large, reconnect) were silent.
        .overlay(alignment: .top) {
            if let toastMessage {
                StatusToastView(toastMessage, icon: "xmark.circle.fill", iconColor: .orange)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onAppear { connectionManager.statusToast = nil }   // drop a stale message from before this window existed
        .onChange(of: connectionManager.statusToast) { _ in
            guard let message = connectionManager.statusToast else { return }
            connectionManager.statusToast = nil
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { toastMessage = message }
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                withAnimation(.easeOut(duration: 0.3)) { toastMessage = nil }
            }
        }
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
