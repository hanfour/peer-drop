import SwiftUI
import PeerDropCore
import PeerDropPlatform

@main
struct PeerDropMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) var appDelegate

    @StateObject private var connectionManager = ConnectionManager()

    var body: some Scene {
        // Main window: discovery + sidebar navigation (filled in Task 5).
        WindowGroup("PeerDrop", id: "PeerDropMain") {
            MacContentView()
                .environmentObject(connectionManager)
                .environmentObject(appDelegate)
                .frame(minWidth: 720, minHeight: 480)
                .onAppear {
                    // Wire AppDelegate's weak ref so lifecycle hooks
                    // (terminate flush) can reach ConnectionManager.
                    appDelegate.connectionManager = connectionManager
                }
        }
        .commands { PeerDropCommands() }

        // Per-peer chat windows (Task 7). Opens via openWindow(id:value:) from
        // any View; multiple chats can live side-by-side per spec §4
        // multi-window strategy. ⌘1 focuses the most-recently-opened chat.
        WindowGroup(id: "chat", for: String.self) { $peerID in
            if let peerID {
                MacChatWindow(peerID: peerID)
                    .environmentObject(connectionManager)
            } else {
                Text("No peer selected")
                    .frame(minWidth: 480, minHeight: 360)
            }
        }
        .keyboardShortcut("1", modifiers: .command)

        // Settings scene (⌘,)
        Settings {
            MacSettingsView()
                .environmentObject(connectionManager)
                .frame(width: 520, height: 360)
        }

        // Menu bar item — visibility bound to AppDelegate's @Published flag.
        // `@NSApplicationDelegateAdaptor` doesn't expose a projected value,
        // so we build the Binding manually against the delegate instance.
        MenuBarExtra(
            isInserted: Binding(
                get: { appDelegate.menuBarVisible },
                set: { appDelegate.menuBarVisible = $0 }
            )
        ) {
            MenuBarContent()
                .environmentObject(connectionManager)
                .frame(width: 360, height: 500)
        } label: {
            // Use ConnectionManager.state (public, M1d-5). The plan's
            // `aggregateState` term doesn't exist on the actual API.
            MenuBarStatusIcon(state: connectionManager.state)
        }
        .menuBarExtraStyle(.window)
    }
}
