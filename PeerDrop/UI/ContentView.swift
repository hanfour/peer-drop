import SwiftUI

struct ContentView: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @State private var selectedTab = 0
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var showShareSheet = false
    @State private var receivedFileURL: URL?

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                NearbyTab()
            }
            .tabItem {
                Label("Nearby", systemImage: "wifi")
            }
            .tag(0)

            NavigationStack {
                ConnectedTab()
            }
            .tabItem {
                Label("Connected", systemImage: "link")
            }
            .tag(1)

            NavigationStack {
                LibraryTab()
            }
            .tabItem {
                Label("Library", systemImage: "archivebox")
            }
            .tag(2)
        }
        .sheet(item: $connectionManager.pendingIncomingRequest) { request in
            ConsentSheet(request: request)
                .environmentObject(connectionManager)
        }
        .sheet(isPresented: $connectionManager.showTransferProgress) {
            TransferProgressView()
                .environmentObject(connectionManager)
        }
        .sheet(isPresented: $connectionManager.showVoiceCall) {
            VoiceCallView()
                .environmentObject(connectionManager)
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = receivedFileURL {
                ShareSheet(items: [url])
            }
        }
        .alert("Connection Error", isPresented: $showError) {
            if connectionManager.canReconnect {
                Button("Reconnect") {
                    connectionManager.reconnect()
                }
            }
            Button("Back to Discovery", role: .cancel) {
                connectionManager.transition(to: .discovering)
                connectionManager.restartDiscovery()
                selectedTab = 0
            }
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
        .onChange(of: connectionManager.state) { _ in
            switch connectionManager.state {
            case .connected, .transferring, .voiceCall:
                selectedTab = 1
            case .failed(let reason):
                errorMessage = reason
                showError = true
            case .rejected:
                errorMessage = "The peer declined your connection request."
                showError = true
            default:
                break
            }
        }
        .onChange(of: connectionManager.fileTransfer?.receivedFileURL) { _ in
            if let url = connectionManager.fileTransfer?.receivedFileURL {
                receivedFileURL = url
                showShareSheet = true
                connectionManager.fileTransfer?.receivedFileURL = nil
            }
        }
    }
}

/// UIKit share sheet wrapper for saving/sharing received files.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
