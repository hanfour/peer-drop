import SwiftUI

struct NearbyTab: View {
    @Binding var selectedTab: Int
    @EnvironmentObject var connectionManager: ConnectionManager
    @AppStorage("peerDropViewMode") private var isGridMode = false
    @AppStorage("peerDropSortMode") private var sortModeRaw = "name"
    @AppStorage("peerDropIsOnline") private var isOnline = true
    @State private var showManualConnect = false
    @State private var editingPeer: DiscoveredPeer?
    @State private var showSettings = false
    @State private var showTransferHistory = false
    @State private var showRelayConnect = false
    @State private var showConnectionQR = false
    @State private var showOptionsSheet = false
    @State private var isSearchActive = false
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool
    @EnvironmentObject var connectionContext: ConnectionContext

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

    private var networkPeers: [DiscoveredPeer] {
        filteredPeers.filter { $0.source != .bluetooth }
    }

    private var bleOnlyPeers: [DiscoveredPeer] {
        filteredPeers.filter { $0.source == .bluetooth }
    }

    /// Show the recommendation card only when it's contextually useful.
    /// `useInviteKnownDevice` is suppressed when local peers exist —
    /// inviting a remote relay device is irrelevant if you already see local options.
    private var shouldShowGuidance: Bool {
        guard isOnline else { return false }
        switch connectionContext.primaryRecommendation {
        case .useInviteKnownDevice:
            return connectionManager.discoveredPeers.isEmpty
        case .useTailnet, .useRelayCode, .configureTailscale:
            return true
        case .useQRScan, .waitForDiscovery:
            return false
        }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
            if shouldShowGuidance {
                GuidanceCard(onMoreOptions: { showOptionsSheet = true }, onDismiss: nil)
            }
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
                        if !networkPeers.isEmpty {
                        Section {
                            ForEach(networkPeers) { peer in
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
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    if peer.source == .manual {
                                        Button(role: .destructive) {
                                            connectionManager.removeManualPeer(id: peer.id)
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                                .swipeActions(edge: .leading) {
                                    if peer.source == .manual {
                                        Button {
                                            editingPeer = peer
                                        } label: {
                                            Label("Edit", systemImage: "pencil")
                                        }
                                        .tint(.blue)
                                    }
                                }
                                .disabled(isConnecting)
                            }
                        } header: {
                            HStack {
                                Label("Local Network", systemImage: "wifi")
                                Spacer()
                                Text("\(networkPeers.count)")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.blue, in: Capsule())
                            }
                        }
                        }

                        if !bleOnlyPeers.isEmpty {
                        Section {
                            ForEach(bleOnlyPeers) { peer in
                                PeerRowView(peer: peer) {
                                    connectionManager.requestConnection(to: peer)
                                }
                                .disabled(isConnecting)
                            }
                        } header: {
                            HStack {
                                Label("Bluetooth", systemImage: "wave.3.right")
                                Spacer()
                                Text("\(bleOnlyPeers.count)")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.cyan, in: Capsule())
                            }
                        } footer: {
                            if FeatureSettings.isRelayEnabled {
                                Text("Use Relay Connect to transfer files with this device")
                            } else {
                                Text("These devices were discovered via Bluetooth. Connect to the same WiFi network to transfer files.")
                            }
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

                // Search bar footer (shown when search is active)
                if isSearchActive {
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
                    Button("Cancel") {
                        connectionManager.disconnect()
                    }
                    .buttonStyle(.bordered)
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
                .accessibilityIdentifier("quick-connect-button")
                .accessibilityLabel("Quick Connect")

                Button {
                    isGridMode.toggle()
                } label: {
                    Image(systemName: isGridMode ? "list.bullet" : "square.grid.2x2")
                }
                .accessibilityIdentifier("grid-toggle-button")
                .accessibilityLabel(isGridMode ? "Switch to list" : "Switch to grid")

                // Search button
                if isOnline && !connectionManager.discoveredPeers.isEmpty {
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
                    }
                    .accessibilityLabel(isSearchActive ? "Close search" : "Search devices")
                }

                if FeatureSettings.isRelayEnabled {
                    Button {
                        showRelayConnect = true
                    } label: {
                        Image(systemName: "antenna.radiowaves.left.and.right.circle")
                    }
                    .accessibilityIdentifier("relay-connect-button")
                    .accessibilityLabel("Relay Connect")
                }

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
                            showConnectionQR = true
                        } label: {
                            Label("My QR Code", systemImage: "qrcode")
                        }
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
                .accessibilityIdentifier("more-options-menu")
                .accessibilityLabel("More options")
            }
        }
        .sheet(isPresented: $showManualConnect) {
            ManualConnectView()
                .environmentObject(connectionManager)
        }
        .sheet(item: $editingPeer) { peer in
            ManualConnectView(editingPeer: peer)
                .environmentObject(connectionManager)
        }
        .sheet(isPresented: $showConnectionQR) {
            ConnectionQRView()
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
        .sheet(isPresented: $showRelayConnect, onDismiss: {
            connectionManager.shouldShowRelayConnect = false
        }) {
            RelayConnectView()
                .environmentObject(connectionManager)
        }
        .sheet(isPresented: $showOptionsSheet) {
            ConnectionOptionsSheet()
                .environmentObject(connectionManager)
                .environmentObject(connectionContext)
        }
        .onChange(of: connectionManager.shouldShowRelayConnect) { shouldShow in
            if shouldShow && !showRelayConnect {
                showRelayConnect = true
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
        .onChange(of: connectionManager.state) { _ in
            // Reset search when connection state changes
            if isSearchActive {
                switch connectionManager.state {
                case .requesting, .connecting, .connected:
                    isSearchActive = false
                    searchText = ""
                default:
                    break
                }
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
        // Check multi-connection first
        if connectionManager.isConnected(to: peer.id) {
            return true
        }
        // Fallback to legacy single-connection check
        guard case .connected = connectionManager.state else { return false }
        return connectionManager.lastConnectedPeer?.id == peer.id
    }

    // MARK: - Search Bar Footer

    private var searchBarFooter: some View {
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
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
