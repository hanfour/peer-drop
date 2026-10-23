import SwiftUI
import PeerDropCore
import PeerDropTransport
import PeerDropPlatform

/// All of NearbyTab's modal sheets routed through a single
/// `.sheet(item:)` binding. Replaces the previous seven parallel
/// `.sheet` modifiers, which logged "[Invalid Configuration] Currently,
/// only presenting a single sheet is supported" any time SwiftUI saw
/// two of them go truthy in the same render. ContentView's security
/// sheets got the same treatment in commit 7024c26 — this lifts the
/// last cluster.
private enum NearbyTabSheet: Identifiable {
    case manualConnect
    case editPeer(DiscoveredPeer)
    case connectionQR
    case relayConnect
    case options
    #if os(macOS)
    case transferHistory
    #endif

    var id: String {
        switch self {
        case .manualConnect:    return "manualConnect"
        case .editPeer(let p):  return "editPeer:\(p.id)"
        case .connectionQR:     return "connectionQR"
        case .relayConnect:     return "relayConnect"
        case .options:          return "options"
        #if os(macOS)
        case .transferHistory:  return "transferHistory"
        #endif
        }
    }
}

struct NearbyTab: View, PaperThemed {
    /// Nearby is always the live look; children read it through the environment.
    var paperMode: PaperMode { .live }
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var selectedTab: Int
    @EnvironmentObject var connectionManager: ConnectionManager
    #if os(macOS)
    // Round 10 audit fix: on Mac, tapping a connected peer needs to
    // open the per-peer chat WindowGroup defined in PeerDropMacApp,
    // not flip an iOS-only TabView index. Environment-injected SwiftUI
    // window dispatcher.
    @Environment(\.openWindow) private var openWindow
    #endif
    @AppStorage("peerDropViewMode") private var isGridMode = false
    @AppStorage("peerDropSortMode") private var sortModeRaw = "name"
    @AppStorage("peerDropIsOnline") private var isOnline = true
    @State private var activeSheet: NearbyTabSheet?
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
    /// - `useInviteKnownDevice` suppressed when local peers exist (local route preferred)
    ///   or when already in an active session (recommending what you're doing makes no sense).
    /// - All recommendations suppressed during active connection/transfer/voice call.
    private var shouldShowGuidance: Bool {
        guard isOnline else { return false }
        switch connectionManager.state {
        case .connected, .transferring, .voiceCall, .connecting, .requesting, .incomingRequest:
            return false
        default: break
        }
        switch connectionContext.primaryRecommendation {
        case .useInviteKnownDevice:
            return connectionManager.discoveredPeers.isEmpty
        case .useTailnet, .useRelayCode, .configureTailscale:
            return true
        case .useQRScan, .waitForDiscovery:
            return false
        }
    }

    /// There is no QR scanner anywhere in the app (ConnectionQRView only displays a code), so no scan entry.
    private static let hasScanner = false

    private func presence(of peer: DiscoveredPeer, _ sources: PresenceSources) -> PeerPresence {
        PeerPresenceResolver.presence(ids: [peer.id], sources: sources)
    }

    var body: some View {
        // One presence snapshot per body update.
        let sources = connectionManager.presenceSources()
        return ZStack {
            VStack(spacing: 0) {
            // Always shown, even offline: QR / manual / invite stay reachable.
            // The relay entry row lives in the list; the Invite Link quick action
            // opens the same RelayConnectView, so grid mode and the Searching state need no extra row.
            quickActionsBar
            if shouldShowGuidance {
                GuidanceCard(onMoreOptions: { activeSheet = .options }, onDismiss: nil)
            }
            Group {
                if !isOnline {
                    VStack(spacing: 12) {
                        Image(systemName: "antenna.radiowaves.left.and.right.slash")
                            .font(.largeTitle)
                            .foregroundStyle(paper(.datePillText))
                        Text("You are offline")
                            .font(.headline)
                            .foregroundStyle(paper(.incomingText))
                        Text("Tap the antenna icon to go online and discover nearby devices.")
                            .font(.subheadline)
                            .foregroundStyle(paper(.datePillText))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if connectionManager.discoveredPeers.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Searching for nearby devices...")
                            .foregroundStyle(paper(.datePillText))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isGridMode {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 16)], spacing: 16) {
                            ForEach(filteredPeers) { peer in
                                PeerGridItemView(peer: peer, onTap: {
                                    if isConnectedPeer(peer) {
                                        openChatWindow(for: peer.id)
                                    } else {
                                        connectionManager.requestConnection(to: peer)
                                    }
                                }, presence: presence(of: peer, sources))
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
                                PeerRowView(peer: peer, onTap: {
                                    if isConnectedPeer(peer) {
                                        openChatWindow(for: peer.id)
                                    } else {
                                        connectionManager.requestConnection(to: peer)
                                    }
                                }, presence: presence(of: peer, sources), isConnected: isConnectedPeer(peer))
                                .listRowBackground(paper(.incomingBubble))
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
                                            activeSheet = .editPeer(peer)
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
                                    .foregroundStyle(paper(.datePillText))
                                Spacer()
                                Text("\(networkPeers.count)")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(paper(.brand), in: Capsule())
                            }
                        }
                        }

                        if !bleOnlyPeers.isEmpty {
                        Section {
                            ForEach(bleOnlyPeers) { peer in
                                PeerRowView(peer: peer, onTap: {
                                    connectionManager.requestConnection(to: peer)
                                }, presence: presence(of: peer, sources), isConnected: isConnectedPeer(peer))
                                .listRowBackground(paper(.incomingBubble))
                                .disabled(isConnecting)
                            }
                        } header: {
                            HStack {
                                Label("Bluetooth", systemImage: "wave.3.right")
                                    .foregroundStyle(paper(.datePillText))
                                Spacer()
                                Text("\(bleOnlyPeers.count)")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(paper(.brand), in: Capsule())
                            }
                        } footer: {
                            if FeatureSettings.isRelayEnabled {
                                Text("Use Relay Connect to transfer files with this device")
                                    .foregroundStyle(paper(.datePillText))
                            } else {
                                Text("These devices were discovered via Bluetooth. Connect to the same WiFi network to transfer files.")
                                    .foregroundStyle(paper(.datePillText))
                            }
                        }
                        }

                        if FeatureSettings.isRelayEnabled {
                            Section {
                                Button {
                                    activeSheet = .relayConnect
                                } label: {
                                    Label("Connect with invite code (relay)", systemImage: "antenna.radiowaves.left.and.right.circle")
                                        .foregroundStyle(paper(.brand))
                                }
                                .accessibilityIdentifier("relay-connect-button")
                                .listRowBackground(paper(.incomingBubble))
                            }
                        }

                        if let error = connectionManager.certificateManager.setupError {
                            Section {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Security Degraded")
                                            .font(.subheadline.bold())
                                            .foregroundStyle(paper(.incomingText))
                                        Text(error)
                                            .font(.caption)
                                            .foregroundStyle(paper(.datePillText))
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
                        .foregroundStyle(paper(.datePillText))
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
        .scrollContentBackground(.hidden)
        .background(paper(.background).ignoresSafeArea())
        .paperMode(.live)
        .navigationTitle("PeerDrop")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
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
            ToolbarItemGroup(placement: .confirmationAction) {
                #if os(macOS)
                // Settings has no Mac sheet and Transfer History lives in iOS SettingsView only.
                Button {
                    activeSheet = .transferHistory
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .accessibilityLabel("Transfer History")
                #endif
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

                Menu {
                    // Picker in a Menu auto-renders a leading checkmark on
                    // the selected option and nothing on the others —
                    // exactly the UX the previous `Label(..., systemImage:
                    // selected ? "checkmark" : "")` workaround tried to
                    // hand-roll. The workaround logged "No symbol named ''
                    // found in system symbol set" on every menu open
                    // because the empty-string branch hit the SF Symbol
                    // resolver. Picker has none of that.
                    Picker("Sort By", selection: $sortModeRaw) {
                        Text("Name").tag(SortMode.name.rawValue)
                        Text("Last Connected").tag(SortMode.lastConnected.rawValue)
                        Text("Connection Count").tag(SortMode.connectionCount.rawValue)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityIdentifier("more-options-menu")
                .accessibilityLabel("More options")
            }
        }
        .sheet(item: $activeSheet, onDismiss: {
            // The relay-connect sheet needs to clear the
            // ConnectionManager flag that originally raised it; the
            // other sheets are pure local state. Inspecting which
            // sheet just closed from inside this callback isn't
            // possible — activeSheet is already nil — so we always
            // clear the flag. It's a no-op when the dismissed sheet
            // was something else.
            connectionManager.shouldShowRelayConnect = false
        }) { sheet in
            switch sheet {
            case .manualConnect:
                ManualConnectView()
                    .environmentObject(connectionManager)
            case .editPeer(let peer):
                ManualConnectView(editingPeer: peer)
                    .environmentObject(connectionManager)
            case .connectionQR:
                ConnectionQRView()
                    .environmentObject(connectionManager)
            case .relayConnect:
                RelayConnectView()
                    .environmentObject(connectionManager)
            #if os(macOS)
            case .transferHistory:
                NavigationStack {
                    TransferHistoryView()
                        .environmentObject(connectionManager)
                }
            #endif
            case .options:
                ConnectionOptionsSheet()
                    .environmentObject(connectionManager)
                    .environmentObject(connectionContext)
            }
        }
        .onChange(of: connectionManager.shouldShowRelayConnect) { shouldShow in
            if shouldShow, activeSheet == nil {
                activeSheet = .relayConnect
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

    // MARK: - Quick actions

    private func quickActionInfo(_ action: NearbyQuickAction) -> (title: LocalizedStringKey, icon: String, id: String, sheet: NearbyTabSheet) {
        switch action {
        case .qr:     return ("My QR Code", "qrcode", "quick-action-qr", .connectionQR)
        case .manual: return ("Manual Connect", "bolt.horizontal.fill", "quick-connect-button", .manualConnect)
        case .invite: return ("Invite Link", "link", "quick-action-invite", .relayConnect)
        case .scan:   return ("Scan", "qrcode.viewfinder", "quick-action-scan", .connectionQR)
        }
    }

    private var quickActionsBar: some View {
        let actions = NearbyQuickAction.available(relayEnabled: FeatureSettings.isRelayEnabled,
                                                  hasScanner: Self.hasScanner)
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            ForEach(actions, id: \.self) { action in
                let info = quickActionInfo(action)
                Button { activeSheet = info.sheet } label: {
                    let content = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(HStackLayout(spacing: 12))
                        : AnyLayout(VStackLayout(spacing: 4))
                    content {
                        Image(systemName: info.icon)
                            .font(.title3)
                            .foregroundStyle(paper(.brand))
                        Text(info.title)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(paper(.incomingText))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(paper(.incomingBubble)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(paper(.border), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(info.id)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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

    /// Cross-platform "open chat" dispatcher. iOS flips the TabView's
    /// selected index so the existing chat tab focuses the right peer
    /// (via the iOS ContentView routing). Mac opens a fresh per-peer
    /// chat WindowGroup defined in PeerDropMacApp.
    private func openChatWindow(for peerID: String) {
        #if os(macOS)
        openWindow(id: "chat", value: peerID)
        #else
        selectedTab = 1
        #endif
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
