import SwiftUI

struct DiscoveryView: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @State private var showManualConnect = false

    var body: some View {
        List {
            Section {
                if connectionManager.discoveredPeers.isEmpty {
                    HStack {
                        ProgressView()
                            .padding(.trailing, 8)
                        Text("Searching for nearby devices...")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    ForEach(connectionManager.discoveredPeers) { peer in
                        PeerRowView(peer: peer) {
                            connectionManager.requestConnection(to: peer)
                        }
                    }
                }
            } header: {
                Text("Nearby Devices")
            }

            Section {
                Button {
                    showManualConnect = true
                } label: {
                    Label("Connect by IP Address", systemImage: "network")
                }
            } header: {
                Text("Tailscale / Manual")
            }
        }
        .refreshable {
            connectionManager.restartDiscovery()
        }
        .sheet(isPresented: $showManualConnect) {
            ManualConnectView()
                .environmentObject(connectionManager)
        }
        .onAppear {
            connectionManager.startDiscovery()
        }
    }
}
