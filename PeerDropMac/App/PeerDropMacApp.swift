import SwiftUI
import PeerDropCore
import PeerDropPlatform
import PeerDropPet
import PeerDropTransport
import PeerDropSecurity

@main
struct PeerDropMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) var appDelegate

    @StateObject private var connectionManager = ConnectionManager()
    /// PetEngine is a separate @StateObject (mirrors iOS
    /// PeerDropApp.swift). The sprite source is
    /// `petEngine.renderedImage: CGImage?` injected as an
    /// `@EnvironmentObject` into every scene that may show the pet.
    @StateObject private var petEngine = PetEngine()
    /// Round 11 audit fix: NearbyTab + GuidanceCard read this object
    /// via `@EnvironmentObject` to drive the discovery-help heuristics.
    /// Without it, the SwiftUI environment lookup fatals at first
    /// render of the Mac sidebar's Nearby section. Mirrors iOS
    /// PeerDropApp.swift:12.
    @StateObject private var connectionContext = ConnectionContext()
    /// Round 11 audit fix: ChatBubbleView reads this object via
    /// `@EnvironmentObject` to play voice-message attachments. Without
    /// it, opening any Mac chat window crashes on the first bubble
    /// render. Mirrors iOS PeerDropApp.swift:13.
    @StateObject private var voicePlayer = VoicePlayer()
    /// Relay invite queue. Routes APNs chat-invite pushes to the
    /// peer-message pipeline once the relay WebSocket reconnects.
    /// Without this, push wake-ups for chat invites are dropped.
    /// Mirrors iOS PeerDropApp.swift:15.
    @StateObject private var inboxService = InboxService()
    /// Soak-window metrics for the v5.4 relay crypto hardening
    /// (PR series #37–#44). Mirrors iOS PeerDropApp.swift:16.
    @StateObject private var cryptoMetrics = CryptoHardeningMetrics()
    /// Validates worker-served crypto policy upgrades against the
    /// public-key set in Info.plist's `CryptoPolicyPublicKeys`. Without
    /// this, the app stays on the bundled default policy (legacy/warn)
    /// — shipping-safe but stuck. Mirrors iOS PeerDropApp.swift:17.
    @StateObject private var policyStore: SecurityPolicyStore = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Security")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bundledKeys: [Data] = (Bundle.main.object(forInfoDictionaryKey: "CryptoPolicyPublicKeys") as? [String])?
            .compactMap { Data(base64Encoded: $0) } ?? []
        let workerURLString = UserDefaults.standard.string(forKey: "peerDropWorkerURL")
            ?? "https://peerdrop-signal.hanfourhuang.workers.dev"
        let workerURL = URL(string: workerURLString)
        return SecurityPolicyStore(
            storageDirectory: dir,
            publicKeys: bundledKeys,
            metrics: nil,
            baseURL: workerURL
        )
    }()

    var body: some Scene {
        // Main window: discovery + sidebar navigation.
        WindowGroup("PeerDrop", id: "PeerDropMain") {
            MacContentView()
                .environmentObject(connectionManager)
                .environmentObject(petEngine)
                .environmentObject(connectionContext)
                .environmentObject(voicePlayer)
                .environmentObject(appDelegate)
                .frame(minWidth: 720, minHeight: 480)
                .onAppear {
                    // Wire AppDelegate's weak ref so lifecycle hooks
                    // (terminate flush) can reach ConnectionManager.
                    appDelegate.connectionManager = connectionManager

                    // Round 11 audit fix: wire ConnectionContext to the
                    // live data sources NearbyTab + GuidanceCard read.
                    // Mirrors iOS PeerDropApp.swift:101-104.
                    connectionContext.observe(
                        deviceStore: connectionManager.deviceStore,
                        tailnetStore: connectionManager.tailnetStore
                    )

                    // Round 6 audit fix: wire MacDropHandler so Finder
                    // / Dock / menu-bar drops can actually call
                    // connectionManager.fileTransfer?.sendFiles(…).
                    // Without this, drops are logged but no data ever
                    // leaves — the Mac value prop "drag-and-drop file
                    // sharing" was a false claim in v6.0 metadata
                    // (Apple Guideline 2.3 reject risk).
                    MacDropHandler.connectionManager = connectionManager

                    // Round 8 audit fix: wire the URL-scheme deep-link
                    // handler. Same lifecycle as MacDropHandler — the
                    // SwiftUI-owned ConnectionManager is the canonical
                    // source. Without this, peerdrop:// URLs were
                    // misrouted through MacDropHandler as if they were
                    // file drops.
                    MacDeepLinkHandler.connectionManager = connectionManager

                    // Round 9 audit fix: wire menu commands. Peer >
                    // Refresh Discovery (⌘R) calls
                    // connectionManager.restartDiscovery() via this
                    // static ref. Other stub menu items were removed
                    // entirely so the menubar doesn't expose inert
                    // affordances to App Store reviewers.
                    MacCommandHandler.connectionManager = connectionManager

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

                    // Decline / timeout / cold-launch-expire all fire
                    // onEndCall(). Without this hook, VoiceCallManager
                    // wouldn't tear down its WebRTC session if one was
                    // already mid-setup (e.g. an outgoing call that the
                    // remote end never picked up). Calling endCall() is
                    // idempotent — no-op if no session is live.
                    provider.onEndCall = { [weak connectionManager] in
                        connectionManager?.voiceCallManager?.endCall()
                    }

                    // M4 audit fix: wire crypto-policy + metrics into
                    // ConnectionManager. Matches iOS PeerDropApp.swift:111-119.
                    // The lazy @StateObject init can't reference these so we
                    // assign at .onAppear. PreKeyStore reads `activePolicy`
                    // off the background-thread saveSync path; the
                    // .onReceive(policyStore.$current) below keeps it fresh.
                    connectionManager.policyStore = policyStore
                    connectionManager.cryptoMetrics = cryptoMetrics
                    connectionManager.remoteSessionManager.policyStore = policyStore
                    connectionManager.remoteSessionManager.cryptoMetrics = cryptoMetrics

                    // M4 screenshot mode (Task 6): when the
                    // -SCREENSHOT_MODE launch arg is set (fastlane
                    // snapshot), populate the Pet + auto-start
                    // discovery with mock peers so MAS screenshots
                    // capture a populated UI without real network.
                    if ScreenshotModeProvider.shared.isActive {
                        petEngine.pet = ScreenshotModeProvider.shared.mockPetState
                        connectionManager.startDiscovery()
                    } else {
                        // M3: kick APNs registration. Matches iOS
                        // PeerDropApp.swift pattern. UN permission dialog
                        // shows once; subsequent launches re-register silently.
                        Task {
                            await PushNotificationManager.shared.requestAuthorizationAndRegister()
                        }
                        // M4 audit fix: observe StoreKit transactions so
                        // refunded / replayed / family-shared Mac tip-jar
                        // IAPs are completed correctly. Without this, the
                        // Mac App Store can charge the user but the app
                        // never marks the transaction finished — receipt
                        // queue grows, future buys re-fire old transactions.
                        // Mirrors iOS PeerDropApp.swift:92.
                        TipJarManager.shared.startObservingTransactions()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .didReceiveRelayPush)) { notification in
                    // M4 audit fix: route relay-pushed chat invites to the
                    // live InboxService (queued PeerMessage pickup once the
                    // relay WebSocket reconnects). Without this, Mac users
                    // get APNs alerts they can't actually act on.
                    guard let userInfo = notification.userInfo else { return }
                    PushNotificationManager.shared.handleRemoteNotification(userInfo, inboxService: inboxService)
                }
                .task {
                    // Round 5 audit fix: drain any APNs payloads buffered by
                    // MacAppDelegate before this scene mounted. Cold-launch
                    // path: app was launched by an APNs tap, so
                    // didReceiveRemoteNotification fires BEFORE the scene
                    // exists. The NotificationCenter post in that window
                    // has no subscriber — without draining, the chat invite
                    // is silently lost.
                    let pending = appDelegate.pendingRelayPushPayloads
                    appDelegate.pendingRelayPushPayloads.removeAll()
                    for userInfo in pending {
                        PushNotificationManager.shared.handleRemoteNotification(userInfo, inboxService: inboxService)
                    }
                }
                .onReceive(policyStore.$current) { newPolicy in
                    // Re-snapshot activePolicy on every policy update so the
                    // background-thread C4 prune path picks up changes without
                    // an app restart. Mirrors iOS PeerDropApp.swift:79-85.
                    connectionManager.preKeyStore.activePolicy = newPolicy
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
                    .environmentObject(connectionContext)
                    .environmentObject(voicePlayer)
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
                .environmentObject(connectionContext)
                .environmentObject(voicePlayer)
                .frame(width: 520, height: 420)
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
                .environmentObject(connectionContext)
                .environmentObject(voicePlayer)
                .frame(width: 360, height: 500)
        } label: {
            // Use ConnectionManager.state (public, M1d-5). The plan's
            // `aggregateState` term doesn't exist on the actual API.
            MenuBarStatusIcon(state: connectionManager.state)
        }
        .menuBarExtraStyle(.window)
    }
}
