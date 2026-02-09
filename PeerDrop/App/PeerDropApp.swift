import SwiftUI

@main
struct PeerDropApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var connectionManager = ConnectionManager()
    @StateObject private var voicePlayer = VoicePlayer()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showLaunch = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environmentObject(connectionManager)
                    .environmentObject(voicePlayer)
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

                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    showLaunch = false
                }
            }
        }
        .onChange(of: scenePhase) { newPhase in
            connectionManager.handleScenePhaseChange(newPhase)
        }
    }
}
