import SwiftUI

@main
struct PeerDropApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var connectionManager = ConnectionManager()
    @State private var showLaunch = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environmentObject(connectionManager)
                    .opacity(showLaunch ? 0 : 1)

                if showLaunch {
                    LaunchScreen()
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.4), value: showLaunch)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    showLaunch = false
                }
            }
        }
    }
}
