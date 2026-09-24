import SwiftUI
import PeerDropCore
import PeerDropTransport
import PeerDropSecurity
import PeerDropPlatform
import PeerDropDiary

@main
struct PeerDropApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var connectionManager = ConnectionManager()
    @StateObject private var connectionContext = ConnectionContext()
    @StateObject private var voicePlayer = VoicePlayer()
    @StateObject private var inboxService = InboxService()
    // Persistence-backed so undelivered soak counters survive OS termination
    // (a background upload that fails, then the OS kills the suspended app,
    // must not silently lose error signals — spec §8.6). Residual is loaded
    // on launch and persisted after each background flush.
    @StateObject private var cryptoMetrics = CryptoHardeningMetrics(
        persistenceURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("crypto-metrics-residual.json")
    )
    @StateObject private var policyStore: SecurityPolicyStore = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Security")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bundledKeys: [Data] = (Bundle.main.object(forInfoDictionaryKey: "CryptoPolicyPublicKeys") as? [String])?
            .compactMap { Data(base64Encoded: $0) } ?? []
        // NOTE: metrics are wired separately — StateObject initializers cannot
        // reference other instance properties (Swift restriction). Pass nil here;
        // the metrics path is exercised by SecurityPolicyStore's own unit tests.
        // Reuse the worker URL that the rest of the app uses (UserDefaults
        // override takes precedence; falls back to the production hardcoded URL).
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
    @Environment(\.scenePhase) private var scenePhase
    @State private var showLaunch = true
    @State private var pendingInvite: InvitePayload?
    @State private var showInviteAccept = false

    init() {
        // Explicit wiring of platform dependencies. The struct defaults already
        // resolve to iOS adapters on iOS, but binding the registry here makes
        // M2 (macOS) wiring trivially symmetric: replace with .init(
        //   pasteboard: { AppKitPasteboard() }, ...) and the rest of the app
        // is untouched.
        PlatformDependencies.shared = PlatformDependencies()
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environmentObject(connectionManager)
                    .environmentObject(connectionContext)
                    .environmentObject(voicePlayer)
                    .environmentObject(inboxService)
                    .environmentObject(cryptoMetrics)
                    .environmentObject(policyStore)
                    .opacity(showLaunch ? 0 : 1)

                if showLaunch {
                    LaunchScreen()
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.4), value: showLaunch)
            .onReceive(NotificationCenter.default.publisher(for: .didReceiveRelayPush)) { notification in
                guard let userInfo = notification.userInfo else { return }
                PushNotificationManager.shared.handleRemoteNotification(userInfo, inboxService: inboxService)
            }
            .onReceive(NotificationCenter.default.publisher(for: .didReceiveNotePush)) { _ in
                // `syncNotes()` forces the `diaryStore` lazy first so a
                // `diaryKey` item already sitting in the inbox can be
                // installed instead of aborting the round (see its doc).
                Task { await connectionManager.syncNotes() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .didReceiveDiaryPush)) { notification in
                guard let kind = notification.userInfo?["kind"] as? String,
                      let diaryId = notification.userInfo?["diaryId"] as? String else { return }
                let accountId = notification.userInfo?["accountId"] as? String
                Task { await connectionManager.diaryStore.handlePush(kind: kind, diaryId: diaryId, accountId: accountId) }
            }
            .onReceive(policyStore.$current) { newPolicy in
                // PR3 follow-up: re-snapshot `activePolicy` on every policy update so
                // PR4's async worker fetch reaches the background-thread C4 prune path
                // without requiring an app restart. Fires once on subscription (initial
                // value) and again on every `policyStore.current` mutation.
                connectionManager.preKeyStore.activePolicy = newPolicy
            }
            .task {
                await PushNotificationManager.shared.requestAuthorizationAndRegister()
                await ConnectionMetrics.shared.fetchRemoteConfig()
                // Drain out-of-band IAP transactions (refund, replay,
                // family-sharing-share). Cheap; idempotent. Settings'
                // TipJarSection drives interactive purchases separately.
                TipJarManager.shared.startObservingTransactions()
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
                    connectionManager.configureVoiceCalling(callProvider: callKit)
                }

                // F2: let AppDelegate's didReceiveRemoteNotification await
                // the diary/diaryKey sync directly instead of racing the
                // background-fetch completion handler against it.
                appDelegate.connectionManager = connectionManager

                // Wire SecurityPolicyStore + CryptoHardeningMetrics into ConnectionManager.
                // Done at .onAppear (not @StateObject lazy init) because the lazy
                // initializer can't reference other instance properties. Future
                // tasks (PR3/PR5/PR6) consume these via connectionManager.policyStore
                // and connectionManager.cryptoMetrics at each enforcement site.
                connectionManager.policyStore = policyStore
                connectionManager.cryptoMetrics = cryptoMetrics
                connectionManager.remoteSessionManager.policyStore = policyStore
                connectionManager.remoteSessionManager.cryptoMetrics = cryptoMetrics
                // Task 3.8: C4 prune wiring — PreKeyStore runs the consumed-OPK
                // prune pass on every saveSync when a policy is available.
                // `policyStore` and `cryptoMetrics` are stable references and only
                // need a one-shot assignment here. `activePolicy` (the value-copy
                // snapshot consumed from the background-thread saveSync path) is
                // refreshed reactively via the `.onReceive(policyStore.$current)`
                // subscription above — so PR4's async worker fetches propagate
                // without requiring an app restart.
                connectionManager.preKeyStore.policyStore = policyStore
                connectionManager.preKeyStore.cryptoMetrics = cryptoMetrics

                // Task 5.3: async-init the OPK retry queue + start the periodic
                // retry loop. Mirrors the policyStore / cryptoMetrics pattern —
                // OutboundRetryQueue.init is async throws so it must be constructed
                // outside the synchronous @StateObject initializer.
                Task {
                    let securityDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("Security")
                    try? FileManager.default.createDirectory(at: securityDir, withIntermediateDirectories: true)
                    let queueURL = securityDir.appendingPathComponent("outbound-retry-queue.enc")
                    let queue = try? await OutboundRetryQueue(storageURL: queueURL)
                    await MainActor.run {
                        connectionManager.outboundRetryQueue = queue
                        connectionManager.startRetryLoop()
                    }
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

                // Pivot 2026-09: the pet system is gone. Purge whatever the
                // old versions left on disk / in iCloud, once per install.
                LegacyPetDataCleanup.runInBackgroundIfNeeded()

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
        }
        .onChange(of: scenePhase) { newPhase in
            connectionManager.handleScenePhaseChange(newPhase)
            switch newPhase {
            case .background:
                inboxService.disconnect()
                connectionManager.tailnetStore.stopPeriodicProbe()
                Task { await ConnectionMetrics.shared.flush() }
                // Ship the crypto-hardening counters (spec §8.6 soak) on the
                // same background transition. Before this, snapshot() had no
                // consumer and the soak read an empty bucket. Persist the
                // residual AFTER the flush so an undelivered batch survives
                // OS termination and re-sends on the next launch.
                Task {
                    await CryptoMetricsUploader.shared.flush(metrics: cryptoMetrics)
                    cryptoMetrics.persist()
                }
            case .active:
                inboxService.connect()
                connectionManager.tailnetStore.startPeriodicProbe()
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
        case "diary":
            // peerdrop://diary/<diaryId>?code=<code>#k=<key> — spec §3.2.
            // Structural validation only (no query/fragment ever logged);
            // the actual join call re-validates against the server.
            guard DiaryInviteLink.parse(url) != nil else { return }
            Task {
                // Re-tapping a link for a diary this account already
                // belongs to is idempotent server-side (spec §2.1 "join":
                // "已是成員仍執行" — still returns 200), so this also covers
                // "just open the diary I'm already in".
                if let diaryId = try? await connectionManager.diaryStore.join(link: url) {
                    NotificationCenter.default.post(name: .openDiary, object: nil, userInfo: ["diaryId": diaryId])
                }
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
