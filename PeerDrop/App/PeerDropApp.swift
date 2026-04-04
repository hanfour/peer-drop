import SwiftUI

@main
struct PeerDropApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var connectionManager = ConnectionManager()
    @StateObject private var voicePlayer = VoicePlayer()
    @StateObject private var petEngine = PetEngine()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showLaunch = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environmentObject(connectionManager)
                    .environmentObject(voicePlayer)
                    .environmentObject(petEngine)
                    .overlay(FloatingPetView(engine: petEngine).allowsHitTesting(true).ignoresSafeArea())
                    .opacity(showLaunch ? 0 : 1)

                if showLaunch {
                    LaunchScreen()
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.4), value: showLaunch)
            .onAppear {
                // Wire CallKit into ConnectionManager
                if let callKit = appDelegate.callKitManager {
                    connectionManager.configureVoiceCalling(callKitManager: callKit)
                }

                // One-time migration of existing chat data to encrypted format
                if !UserDefaults.standard.bool(forKey: "peerDropDataMigrated") {
                    connectionManager.chatManager.migrateExistingDataToEncrypted()
                    UserDefaults.standard.set(true, forKey: "peerDropDataMigrated")
                }

                // Load saved pet
                if let saved = try? PetStore().load() {
                    petEngine.pet = saved
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
        }
        .onChange(of: scenePhase) { newPhase in
            connectionManager.handleScenePhaseChange(newPhase)
            if newPhase == .background {
                try? PetStore().save(petEngine.pet)
                try? PetCloudSync().syncFullState(petEngine.pet)
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
            guard let hostPort = url.pathComponents.dropFirst().first else { return }
            let parts = hostPort.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let port = UInt16(parts[1]) else { return }
            let host = String(parts[0])
            let name = url.pathComponents.count > 2 ? url.pathComponents[2] : nil
            connectionManager.addManualPeer(host: host, port: port, name: name)
        default:
            break
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
