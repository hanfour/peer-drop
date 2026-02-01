import SwiftUI

struct NearbyTab: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @AppStorage("peerDropViewMode") private var isGridMode = false
    @AppStorage("peerDropSortMode") private var sortModeRaw = "name"
    @State private var showManualConnect = false
    @State private var showSettings = false
    @State private var showTransferHistory = false

    private var sortMode: SortMode {
        SortMode(rawValue: sortModeRaw) ?? .name
    }

    private var sortedPeers: [DiscoveredPeer] {
        let peers = connectionManager.discoveredPeers
        switch sortMode {
        case .name:
            return peers.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        case .lastConnected:
            let records = connectionManager.deviceStore.records
            return peers.sorted { p1, p2 in
                let r1 = records.first { $0.id == p1.id }
                let r2 = records.first { $0.id == p2.id }
                return (r1?.lastConnected ?? .distantPast) > (r2?.lastConnected ?? .distantPast)
            }
        case .connectionCount:
            let records = connectionManager.deviceStore.records
            return peers.sorted { p1, p2 in
                let r1 = records.first { $0.id == p1.id }
                let r2 = records.first { $0.id == p2.id }
                return (r1?.connectionCount ?? 0) > (r2?.connectionCount ?? 0)
            }
        }
    }

    var body: some View {
        ZStack {
            Group {
                if connectionManager.discoveredPeers.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Searching for nearby devices...")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isGridMode {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 16)], spacing: 16) {
                            ForEach(sortedPeers) { peer in
                                PeerGridItemView(peer: peer) {
                                    connectionManager.requestConnection(to: peer)
                                }
                                .disabled(isConnecting)
                            }
                        }
                        .padding()
                    }
                    .refreshable {
                        connectionManager.restartDiscovery()
                    }
                } else {
                    List {
                        Section {
                            ForEach(sortedPeers) { peer in
                                PeerRowView(peer: peer) {
                                    connectionManager.requestConnection(to: peer)
                                }
                                .disabled(isConnecting)
                            }
                        } header: {
                            HStack {
                                Text("Nearby Devices")
                                Spacer()
                                Text("\(connectionManager.discoveredPeers.count)")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.blue, in: Capsule())
                            }
                        }

                        if let error = connectionManager.certificateManager.setupError {
                            Section {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Security Degraded")
                                            .font(.subheadline.bold())
                                        Text(error)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: "exclamationmark.shield.fill")
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                    .animation(.easeInOut(duration: 0.25), value: connectionManager.discoveredPeers)
                    .refreshable {
                        connectionManager.restartDiscovery()
                    }
                }
            }

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
        .navigationTitle("PeerDrop")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showManualConnect = true
                } label: {
                    Image(systemName: "bolt.horizontal.fill")
                }
                .accessibilityLabel("Quick Connect")

                Button {
                    isGridMode.toggle()
                } label: {
                    Image(systemName: isGridMode ? "list.bullet" : "square.grid.2x2")
                }
                .accessibilityLabel(isGridMode ? "Switch to list" : "Switch to grid")

                Menu {
                    Section("Sort By") {
                        Button {
                            sortModeRaw = SortMode.name.rawValue
                        } label: {
                            Label("Name", systemImage: sortMode == .name ? "checkmark" : "")
                        }
                        Button {
                            sortModeRaw = SortMode.lastConnected.rawValue
                        } label: {
                            Label("Last Connected", systemImage: sortMode == .lastConnected ? "checkmark" : "")
                        }
                        Button {
                            sortModeRaw = SortMode.connectionCount.rawValue
                        } label: {
                            Label("Connection Count", systemImage: sortMode == .connectionCount ? "checkmark" : "")
                        }
                    }
                    Section {
                        Button {
                            showSettings = true
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                        Button {
                            showTransferHistory = true
                        } label: {
                            Label("Transfer History", systemImage: "clock.arrow.circlepath")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showManualConnect) {
            ManualConnectView()
                .environmentObject(connectionManager)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showTransferHistory) {
            NavigationStack {
                TransferHistoryView()
                    .environmentObject(connectionManager)
            }
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
    }

    private var isConnecting: Bool {
        switch connectionManager.state {
        case .requesting, .connecting: return true
        default: return false
        }
    }

    private var connectingLabel: String {
        switch connectionManager.state {
        case .requesting: return "Requesting connection..."
        case .connecting: return "Connecting..."
        default: return ""
        }
    }
}
