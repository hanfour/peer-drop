import SwiftUI

struct ContentView: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @State private var errorMessage: String?
    @State private var showError = false

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
            .alert("Connection Error", isPresented: $showError) {
                Button("Retry") {
                    connectionManager.transition(to: .discovering)
                    connectionManager.restartDiscovery()
                }
                Button("Dismiss", role: .cancel) {
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
        }
        .animation(.easeInOut(duration: 0.3), value: connectionManager.state)
    }
}
