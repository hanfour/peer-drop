import SwiftUI
import PeerDropCore

/// Registers the `ChatTarget` -> `ChatView` push destination on the enclosing NavigationStack.
/// Every tab that owns its own NavigationStack and pushes `NavigationLink(value: ChatTarget)`
/// applies this exactly once. macOS opens chats in their own window, so it is a no-op there.
private struct ChatTargetDestination: ViewModifier {
    @EnvironmentObject var connectionManager: ConnectionManager

    func body(content: Content) -> some View {
        #if os(iOS)
        content.navigationDestination(for: ChatTarget.self) { target in
            ChatView(chatManager: connectionManager.chatManager, peerID: target.peerID, peerName: target.name, showsConnectionInfo: true)
                .environmentObject(connectionManager)
        }
        #else
        content
        #endif
    }
}

extension View {
    func chatTargetDestination() -> some View { modifier(ChatTargetDestination()) }
}
