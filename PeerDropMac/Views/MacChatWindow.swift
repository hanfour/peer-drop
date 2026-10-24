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

    /// Matches ChatView's mode so the window ground switches with it.
    private var windowMode: PaperMode {
        ChatPresenceMode.mode(peerID: peerID, connectionManager: connectionManager)
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        .background(PaperTheme.color(.background, mode: windowMode))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: windowMode)
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

    /// The peer's name: discovered peer, else the live connection's identity, else the
    /// saved device record (so a disconnected, not-currently-discovered peer still has
    /// its name), else a neutral phrase — never a raw device id.
    private var peerDisplayName: String {
        ChatDisplayName.preferred(
            connectionManager.discoveredPeers.first(where: { $0.id == peerID })?.displayName,
            connectionManager.connection(for: peerID)?.peerIdentity.displayName,
            connectionManager.deviceStore.records.first(where: { $0.id == peerID })?.displayName
        ) ?? String(localized: "Other person")
    }
}
