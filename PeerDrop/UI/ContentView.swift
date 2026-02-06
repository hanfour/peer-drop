import SwiftUI

struct ContentView: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @State private var selectedTab = 0
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var showShareSheet = false
    @State private var receivedFileURL: URL?
    @State private var showStatusToast = false
    @State private var statusToastMessage: String?

    var body: some View {
        ZStack(alignment: .top) {
        TabView(selection: $selectedTab) {
            NavigationStack {
                NearbyTab(selectedTab: $selectedTab)
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
                // Only show alert if not suppressed (e.g., ChatView handles it locally)
                if !connectionManager.suppressErrorAlert {
                    errorMessage = reason
                    showError = true
                }
            case .rejected:
                // Always show rejected alert (user needs to know)
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
        .onChange(of: connectionManager.statusToast) { _ in
            guard let message = connectionManager.statusToast else { return }
            statusToastMessage = message
            connectionManager.statusToast = nil
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                showStatusToast = true
            }
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                withAnimation(.easeOut(duration: 0.3)) {
                    showStatusToast = false
                }
            }
        }

            // Status toast overlay
            if showStatusToast, let message = statusToastMessage {
                StatusToastView(message, icon: "xmark.circle.fill", iconColor: .orange)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 8)
                    .zIndex(2)
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
