import SwiftUI

@main
struct PeerDropApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var connectionManager = ConnectionManager()
    @StateObject private var connectionContext = ConnectionContext()
    @StateObject private var voicePlayer = VoicePlayer()
    @StateObject private var petEngine = PetEngine()
    @StateObject private var inboxService = InboxService()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showLaunch = true
    @State private var pendingInvite: InvitePayload?
    @State private var showInviteAccept = false
    @State private var showV4UpgradeOnboarding = false
    @State private var showV5UpgradeOnboarding = false

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environmentObject(connectionManager)
                    .environmentObject(connectionContext)
                    .environmentObject(voicePlayer)
                    .environmentObject(petEngine)
                    .environmentObject(inboxService)
                    .overlay(FloatingPetView(engine: petEngine).allowsHitTesting(true).ignoresSafeArea())
                    .opacity(showLaunch ? 0 : 1)

                if showLaunch {
                    LaunchScreen()
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.4), value: showLaunch)
            .onReceive(NotificationCenter.default.publisher(for: .didReceiveRelayPush)) { notification in
                guard let userInfo = notification.userInfo as? [AnyHashable: Any] else { return }
                PushNotificationManager.shared.handleRemoteNotification(userInfo, inboxService: inboxService)
            }
            .task {
                await PushNotificationManager.shared.requestAuthorizationAndRegister()
                await ConnectionMetrics.shared.fetchRemoteConfig()
                // Re-fetch every hour while foregrounded.
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 3600 * 1_000_000_000)
                    if Task.isCancelled { break }
                    await ConnectionMetrics.shared.fetchRemoteConfig()
                }
            }
            .onAppear {
                // Wire ConnectionContext to live signals
                connectionContext.observe(
                    deviceStore: connectionManager.deviceStore,
                    tailnetStore: connectionManager.tailnetStore)

                // Wire CallKit into ConnectionManager
                if let callKit = appDelegate.callKitManager {
                    connectionManager.configureVoiceCalling(callKitManager: callKit)
                }

                // One-time migration of existing chat data to encrypted format
                if !UserDefaults.standard.bool(forKey: "peerDropDataMigrated") {
                    connectionManager.chatManager.migrateExistingDataToEncrypted()
                    UserDefaults.standard.set(true, forKey: "peerDropDataMigrated")
                }

                // Fix stale worker URL from pre-1.3.0 (was missing subdomain)
                if !UserDefaults.standard.bool(forKey: "peerDropWorkerURLMigrated") {
                    let stored = UserDefaults.standard.string(forKey: "peerDropWorkerURL")
                    if stored == "https://peerdrop-signal.workers.dev" {
                        UserDefaults.standard.removeObject(forKey: "peerDropWorkerURL")
                    }
                    UserDefaults.standard.set(true, forKey: "peerDropWorkerURLMigrated")
                }

                // Load pet (mock for screenshots, saved for normal). For real
                // pets we call loadAndMigrate so v3.x → v4.0 upgrades fill in
                // subVariety / seed / migrationDoneAt at first launch.
                // Idempotent — subsequent launches early-return without
                // re-applying.
                if ScreenshotModeProvider.shared.isActive {
                    petEngine.pet = ScreenshotModeProvider.shared.mockPetState
                } else if let saved = try? PetStore().loadAndMigrate() {
                    petEngine.pet = saved
                    // M10 — show the v4.0 upgrade screen once for users
                    // whose pet just got migrated from v3.x. Brand-new v4.0
                    // installs (no migrationDoneAt) skip this.
                    if V4UpgradeOnboarding.shouldPresent(for: petEngine.pet) {
                        showV4UpgradeOnboarding = true
                    } else if V5UpgradeOnboarding.shouldPresent() {
                        // v5 upgrade is mutually exclusive with v4 upgrade in
                        // a single launch — if both fire, v4 gets priority
                        // (it's the older, less-recently-seen one and chains
                        // naturally; the v5 sheet will surface on the next
                        // launch via the AppStorage gate).
                        showV5UpgradeOnboarding = true
                    }
                }

                // Wire pet callbacks
                connectionManager.onPeerConnectedForPet = { _ in
                    petEngine.handleInteraction(.peerConnected)
                }
                connectionManager.onPeerDisconnectedForPet = { _ in
                    petEngine.pet.mood = .lonely
                }
                connectionManager.chatManager.onMessageReceivedForPet = {
                    petEngine.handleChatMessage()
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    showLaunch = false
                }
            }
            .onOpenURL { url in
                handleDeepLink(url)
            }
            .sheet(isPresented: $showInviteAccept) {
                if let invite = pendingInvite {
                    InviteAcceptView(
                        invite: invite,
                        connectionManager: connectionManager
                    ) {
                        showInviteAccept = false
                        pendingInvite = nil
                    }
                }
            }
            .sheet(isPresented: $showV4UpgradeOnboarding) {
                V4UpgradeOnboarding(
                    petImage: petEngine.renderedImage,
                    petName: petEngine.pet.name
                ) {
                    showV4UpgradeOnboarding = false
                }
            }
            .sheet(isPresented: $showV5UpgradeOnboarding) {
                V5UpgradeOnboarding(
                    petImage: petEngine.renderedImage,
                    petName: petEngine.pet.name
                ) {
                    showV5UpgradeOnboarding = false
                }
            }
        }
        .onChange(of: scenePhase) { newPhase in
            connectionManager.handleScenePhaseChange(newPhase)
            switch newPhase {
            case .background:
                inboxService.disconnect()
                connectionManager.tailnetStore.stopPeriodicProbe()
                Task { await ConnectionMetrics.shared.flush() }
                try? PetStore().save(petEngine.pet)
                try? PetCloudSync().syncFullState(petEngine.pet)
                petEngine.syncSharedState()
                petEngine.startLiveActivity()
                // Pause the 6 FPS animation timer to avoid burning CPU/battery
                // while the app is suspended. Resumed on .active.
                petEngine.animator.stopAnimation()
            case .active:
                inboxService.connect()
                connectionManager.tailnetStore.startPeriodicProbe()
                petEngine.endLiveActivity()
                // Resume animation timer (no-op if already running).
                petEngine.animator.startAnimation()
            default:
                break
            }
        }
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "peerdrop" else { return }
        switch url.host {
        case "relay":
            // peerdrop://relay/XXXXXX
            guard let code = url.pathComponents.dropFirst().first,
                  code.count == 6 else { return }
            connectionManager.pendingRelayJoinCode = code.uppercased()
            connectionManager.shouldShowRelayConnect = true
        case "connect":
            // peerdrop://connect/192.168.1.100:9000  or  peerdrop://connect/192.168.1.100:9000/Name
            guard let hostPort = url.pathComponents.dropFirst().first,
                  let (host, port) = parseHostPort(hostPort) else { return }
            let name = url.pathComponents.count > 2 ? url.pathComponents[2] : nil
            connectionManager.addManualPeer(host: host, port: port, name: name)
        case "smart":
            // peerdrop://smart?ts=IP:PORT&local=IP:PORT&relay=CODE&name=NAME
            handleSmartDeepLink(url)
        case "invite":
            do {
                let invite = try InvitePayload(from: url)
                guard invite.expiry > Date() else { return }
                pendingInvite = invite
                showInviteAccept = true
            } catch {
                // Invalid invite URL
            }
        default:
            break
        }
    }

    private func handleSmartDeepLink(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else { return }

        let params = Dictionary(uniqueKeysWithValues: queryItems.compactMap { item in
            item.value.map { (item.name, $0) }
        })
        let name = params["name"]

        // Add all available connection methods — app tries each and uses whichever succeeds
        if let ts = params["ts"], let (host, port) = parseHostPort(ts) {
            connectionManager.addManualPeer(host: host, port: port, name: name)
        }
        if let local = params["local"], let (host, port) = parseHostPort(local) {
            connectionManager.addManualPeer(host: host, port: port, name: name)
        }
        if let relay = params["relay"] {
            connectionManager.pendingRelayJoinCode = relay.uppercased()
            connectionManager.shouldShowRelayConnect = true
        }
    }

    private func parseHostPort(_ value: String) -> (String, UInt16)? {
        let parts = value.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let port = UInt16(parts[1]) else { return nil }
        let host = String(parts[0])
        guard isAllowedPeerHost(host) else { return nil }
        return (host, port)
    }

    /// Reject loopback, link-local, and non-unicast addresses from deep links.
    private func isAllowedPeerHost(_ host: String) -> Bool {
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        // Block loopback (127.x.x.x)
        if octets[0] == 127 { return false }
        // Block link-local (169.254.x.x)
        if octets[0] == 169 && octets[1] == 254 { return false }
        // Block multicast/broadcast (224-255.x.x.x)
        if octets[0] >= 224 { return false }
        // Block 0.x.x.x
        if octets[0] == 0 { return false }
        return true
    }
}
