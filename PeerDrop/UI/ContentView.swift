import SwiftUI

struct ContentView: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var showShareSheet = false
    @State private var receivedFileURL: URL?

    var body: some View {
        NavigationStack {
            Group {
                switch connectionManager.state {
                case .connected, .transferring, .voiceCall:
                    ConnectionView()
                default:
                    DiscoveryView()
                }
            }
            .navigationTitle("PeerDrop")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    if connectionManager.state != .idle {
                        StatusBadge(state: connectionManager.state)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
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
                }
            } message: {
                Text(errorMessage ?? "An unknown error occurred.")
            }
            .onChange(of: connectionManager.state) { _ in
                if case .failed(let reason) = connectionManager.state {
                    errorMessage = reason
                    showError = true
                }
                if case .rejected = connectionManager.state {
                    errorMessage = "The peer declined your connection request."
                    showError = true
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
        .animation(.easeInOut(duration: 0.3), value: connectionManager.state)
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
