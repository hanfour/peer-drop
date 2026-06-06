import SwiftUI
import PeerDropCore
import PeerDropPlatform
import PeerDropPet
import PeerDropTransport

@main
struct PeerDropMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) var appDelegate

    @StateObject private var connectionManager = ConnectionManager()
    // Task 9: PetEngine is a separate @StateObject (matches iOS
    // PeerDropApp.swift:14). The plan referenced
    // `connectionManager.currentPetSprite` which doesn't exist; the real
    // source is `petEngine.renderedImage: CGImage?` injected as an
    // @EnvironmentObject into every scene that may show the sprite.
    @StateObject private var petEngine = PetEngine()

    var body: some Scene {
        // Main window: discovery + sidebar navigation (filled in Task 5).
        WindowGroup("PeerDrop", id: "PeerDropMain") {
            MacContentView()
                .environmentObject(connectionManager)
                .environmentObject(petEngine)
                .environmentObject(appDelegate)
                .frame(minWidth: 720, minHeight: 480)
                .onAppear {
                    // Wire AppDelegate's weak ref so lifecycle hooks
                    // (terminate flush) can reach ConnectionManager.
                    appDelegate.connectionManager = connectionManager

                    // M3: wire MacCallProvider into the cross-platform
                    // CallProvider injection point on ConnectionManager.
                    // Mirror of iOS PeerDropApp.swift:108.
                    let provider = appDelegate.macCallProvider
                    connectionManager.configureVoiceCalling(callProvider: provider)

                    // After user accepts on the panel, fetch the live
                    // VoiceCallManager from ConnectionManager and present
                    // the active-call NSWindow. Display name comes from
                    // discoveredPeers if available, else a fallback.
                    provider.onAnswerCall = { [weak provider, weak connectionManager] in
                        guard let provider, let connectionManager,
                              let voiceCallManager = connectionManager.voiceCallManager
                        else { return }
                        let peerName = connectionManager.discoveredPeers.first?.displayName
                            ?? NSLocalizedString("Peer", comment: "Voice call peer name fallback")
                        provider.showActiveWindow(
                            peerName: peerName,
                            voiceCallManager: voiceCallManager
                        )
                    }

                    // M3: kick APNs registration. Matches iOS
                    // PeerDropApp.swift pattern. UN permission dialog
                    // shows once; subsequent launches re-register silently.
                    Task {
                        await PushNotificationManager.shared.requestAuthorizationAndRegister()
                    }
                }
        }
        .commands { PeerDropCommands() }

        // Per-peer chat windows (Task 7). Opens via openWindow(id:value:) from
        // any View; multiple chats can live side-by-side per spec §4
        // multi-window strategy. The ⌘1 "focus existing chat" affordance is
        // owned by the Window > Chat menu item (PeerDropCommands.swift) —
        // binding it here too would attach ⌘1 to "New Window" (which opens
        // the no-peer fallback), shadowing the menu item.
        WindowGroup(id: "chat", for: String.self) { $peerID in
            if let peerID {
                MacChatWindow(peerID: peerID)
                    .environmentObject(connectionManager)
                    .environmentObject(petEngine)
            } else {
                Text("No peer selected")
                    .frame(minWidth: 480, minHeight: 360)
            }
        }

        // Settings scene (⌘,)
        Settings {
            MacSettingsView()
                .environmentObject(connectionManager)
                .environmentObject(petEngine)
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
                .environmentObject(petEngine)
                .frame(width: 360, height: 500)
        } label: {
            // Use ConnectionManager.state (public, M1d-5). The plan's
            // `aggregateState` term doesn't exist on the actual API.
            MenuBarStatusIcon(state: connectionManager.state)
        }
        .menuBarExtraStyle(.window)
    }
}
