import SwiftUI

struct NearbyTab: View {
    @Binding var selectedTab: Int
    @EnvironmentObject var connectionManager: ConnectionManager
    @AppStorage("peerDropViewMode") private var isGridMode = false
    @AppStorage("peerDropSortMode") private var sortModeRaw = "name"
    @AppStorage("peerDropIsOnline") private var isOnline = true
    @State private var showManualConnect = false
    @State private var showSettings = false
    @State private var showTransferHistory = false
    @State private var isSearchActive = false
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

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

    private var filteredPeers: [DiscoveredPeer] {
        guard !searchText.isEmpty else { return sortedPeers }
        return sortedPeers.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
            Group {
                if !isOnline {
                    VStack(spacing: 12) {
                        Image(systemName: "antenna.radiowaves.left.and.right.slash")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("You are offline")
                            .font(.headline)
                        Text("Tap the antenna icon to go online and discover nearby devices.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if connectionManager.discoveredPeers.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Searching for nearby devices...")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isGridMode {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 16)], spacing: 16) {
                            ForEach(filteredPeers) { peer in
                                PeerGridItemView(peer: peer) {
                                    if isConnectedPeer(peer) {
                                        selectedTab = 1
                                    } else {
                                        connectionManager.requestConnection(to: peer)
                                    }
                                }
                                .disabled(isConnecting)
                            }
                        }
                        .padding()
                    }
                    .refreshable {
                        guard isOnline else { return }
                        connectionManager.restartDiscovery()
                    }
                } else {
                    List {
                        Section {
                            ForEach(filteredPeers) { peer in
                                PeerRowView(peer: peer) {
                                    if isConnectedPeer(peer) {
                                        selectedTab = 1
                                    } else {
                                        connectionManager.requestConnection(to: peer)
                                    }
                                }
                                .overlay(alignment: .trailing) {
                                    if isConnectedPeer(peer) {
                                        Text("Connected")
                                            .font(.caption2.bold())
                                            .foregroundStyle(.green)
                                            .padding(.trailing, 8)
                                    }
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
                        guard isOnline else { return }
                        connectionManager.restartDiscovery()
                    }
                }
            }

                // Search bar footer
                if isOnline && !connectionManager.discoveredPeers.isEmpty {
                    searchBarFooter
                }
            } // End VStack

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
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    isOnline.toggle()
                    if isOnline {
                        connectionManager.startDiscovery()
                    } else {
                        // Disconnect any active connection before going offline
                        switch connectionManager.state {
                        case .connected, .transferring, .voiceCall, .requesting, .connecting:
                            connectionManager.disconnect()
                        default:
                            break
                        }
                        connectionManager.stopDiscovery()
                    }
                } label: {
                    Image(systemName: isOnline ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                        .foregroundStyle(isOnline ? .green : .secondary)
                }
                .accessibilityLabel(isOnline ? "Go offline" : "Go online")
            }
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
                .environmentObject(connectionManager)
        }
        .sheet(isPresented: $showTransferHistory) {
            NavigationStack {
                TransferHistoryView()
                    .environmentObject(connectionManager)
            }
        }
        .onAppear {
            if isOnline, case .idle = connectionManager.state {
                connectionManager.startDiscovery()
            }
        }
        .onChange(of: isOnline) { online in
            if online {
                connectionManager.startDiscovery()
            } else {
                connectionManager.stopDiscovery()
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

    private func isConnectedPeer(_ peer: DiscoveredPeer) -> Bool {
        guard case .connected = connectionManager.state else { return false }
        return connectionManager.lastConnectedPeer?.id == peer.id
    }

    // MARK: - Search Bar Footer

    private var searchBarFooter: some View {
        HStack(spacing: 12) {
            if isSearchActive {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)

                    TextField("Search devices...", text: $searchText)
                        .textFieldStyle(.plain)
                        .focused($isSearchFocused)
                        .submitLabel(.search)

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.systemGray5))
                .clipShape(Capsule())
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .trailing).combined(with: .opacity)
                ))
            }

            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isSearchActive.toggle()
                    if isSearchActive {
                        isSearchFocused = true
                    } else {
                        searchText = ""
                        isSearchFocused = false
                    }
                }
            } label: {
                Image(systemName: isSearchActive ? "xmark" : "magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(isSearchActive ? Color.gray : Color.blue)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }
}
