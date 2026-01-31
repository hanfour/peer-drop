import SwiftUI

struct DiscoveryView: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @State private var showManualConnect = false

    var body: some View {
        ZStack {
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
                            .disabled(isConnecting)
                            .transition(.asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .opacity
                            ))
                        }
                    }
                } header: {
                    HStack {
                        Text("Nearby Devices")
                        Spacer()
                        if !connectionManager.discoveredPeers.isEmpty {
                            Text("\(connectionManager.discoveredPeers.count)")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.blue, in: Capsule())
                        }
                    }
                }

                Section {
                    Button {
                        showManualConnect = true
                    } label: {
                        Label("Connect by IP Address", systemImage: "network")
                    }
                    .disabled(isConnecting)
                } header: {
                    Text("Tailscale / Manual")
                }
            }
            .animation(.easeInOut(duration: 0.25), value: connectionManager.discoveredPeers)
            .refreshable {
                connectionManager.restartDiscovery()
            }
            .sheet(isPresented: $showManualConnect) {
                ManualConnectView()
                    .environmentObject(connectionManager)
            }
            .onAppear {
                if case .idle = connectionManager.state {
                    connectionManager.startDiscovery()
                }
            }
            .onChange(of: connectionManager.discoveredPeers.count) { _ in
                if !connectionManager.discoveredPeers.isEmpty {
                    HapticManager.peerDiscovered()
                }
            }

            // Connection-in-progress overlay
            if isConnecting {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.3)
                    Text(connectingLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.ultraThinMaterial)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isConnecting)
    }

    private var isConnecting: Bool {
        switch connectionManager.state {
        case .requesting, .connecting:
            return true
        default:
            return false
        }
    }

    private var connectingLabel: String {
        switch connectionManager.state {
        case .requesting:
            return "Requesting connection..."
        case .connecting:
            return "Connecting..."
        default:
            return ""
        }
    }
}
