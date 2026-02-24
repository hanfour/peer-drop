import Foundation
import Network
import Combine
import SwiftUI
import UIKit
import os

private let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "ConnectionManager")

/// Convert any error to a user-friendly message for display.
private func userFriendlyErrorMessage(_ error: Error) -> String {
    // Handle NWError from Network framework
    if let nwError = error as? NWError {
        switch nwError {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED: return "Connection refused by peer"
            case .ECONNRESET: return "Connection reset by peer"
            case .ETIMEDOUT: return "Connection timed out"
            case .ENETUNREACH: return "Network unreachable"
            case .EHOSTUNREACH: return "Peer unreachable"
            case .ENOTCONN: return "Not connected"
            default: return "Network error occurred"
            }
        case .tls(let status):
            return "Secure connection failed (TLS error \(status))"
        case .dns(let dnsError):
            return "Could not find peer (\(dnsError))"
        case .wifiAware:
            return "WiFi Aware connection failed"
        @unknown default:
            return "Network connection failed"
        }
    }

    // Handle our custom NWConnectionError
    if let connError = error as? NWConnectionError {
        return connError.localizedDescription
    }

    // For other errors, use localizedDescription but clean it up
    let desc = error.localizedDescription
    // Remove technical prefixes like "PeerDrop.SomeError"
    if desc.contains("(") && desc.contains(")") {
        // Try to extract just the meaningful part
        if let range = desc.range(of: "(", options: .backwards) {
            let prefix = String(desc[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !prefix.isEmpty && !prefix.contains(".") {
                return prefix
            }
        }
    }
    return desc
}


/// Incoming connection request for the consent sheet.
struct IncomingRequest: Identifiable {
    let id = UUID()
    let peerIdentity: PeerIdentity
    let connection: NWConnection
}

/// Central state machine that orchestrates discovery, connections, transfers, and calls.
@MainActor
final class ConnectionManager: ObservableObject {
    // MARK: - Published State

    @Published private(set) var state: ConnectionState = .idle
    @Published private(set) var discoveredPeers: [DiscoveredPeer] = []
    @Published var pendingIncomingRequest: IncomingRequest?
    @Published var showTransferProgress = false
    @Published var showVoiceCall = false
    @Published private(set) var transferProgress: Double = 0
    @Published var transferHistory: [TransferRecord] = [] {
        didSet { saveTransferHistory() }
    }
    @Published var latestToast: TransferRecord?
    @Published var statusToast: String?
    /// When true, the ContentView error alert is suppressed (e.g., user is in ChatView handling the error locally)
    @Published var suppressErrorAlert: Bool = false

    // MARK: - Multi-Connection Support

    /// All active peer connections, keyed by peerID.
    @Published private(set) var connections: [String: PeerConnection] = [:]

    /// The currently focused peer ID for UI interactions.
    @Published var focusedPeerID: String?

    /// Maximum number of simultaneous connections allowed.
    let maxConnections = 5

    /// The currently focused connection, if any.
    var focusedConnection: PeerConnection? {
        guard let id = focusedPeerID else { return nil }
        return connections[id]
    }

    /// Backward-compatible: returns the focused peer's identity.
    var connectedPeer: PeerIdentity? {
        focusedConnection?.peerIdentity
    }

    /// All connected peer identities.
    var connectedPeers: [PeerIdentity] {
        connections.values.filter { $0.state.isConnected }.map { $0.peerIdentity }
    }

    /// Whether any connection is active.
    var hasActiveConnections: Bool {
        !connections.isEmpty && connections.values.contains { $0.state.isActive }
    }

    /// Number of active connections.
    var activeConnectionCount: Int {
        connections.values.filter { $0.state.isActive }.count
    }

    // MARK: - Internal

    private var discoveryCoordinator: DiscoveryCoordinator?
    private var bonjourDiscovery: BonjourDiscovery?
    private var activeConnection: NWConnection?
    private var cancellables = Set<AnyCancellable>()
    private(set) var localIdentity: PeerIdentity
    let certificateManager = CertificateManager()
    private(set) var lastConnectedPeer: DiscoveredPeer?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var requestingTimeoutTask: Task<Void, Never>?
    private var connectingTimeoutTask: Task<Void, Never>?
    private var consentMonitorTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    /// Tracks the current connection attempt so stale callbacks are ignored.
    private var connectionGeneration: UUID = UUID()

    // MARK: - Network Path Monitoring
    private var pathMonitor: NWPathMonitor?
    private var lastNetworkPath: NWPath?

    // MARK: - Consent Timeout
    private var consentTimeoutTask: Task<Void, Never>?
    private let consentTimeoutSeconds: UInt64 = 30

    // MARK: - Exponential Backoff Retry
    private let reconnectController = RetryController()

    // MARK: - Background Time Monitoring
    private var backgroundTimeMonitorTask: Task<Void, Never>?
    private let backgroundWarningThreshold: TimeInterval = 10.0

    // MARK: - Circuit Breaker
    private var failedPeers: [String: (count: Int, lastFailed: Date)] = [:]
    private let circuitBreakerThreshold = 3
    private let circuitBreakerCooldown: TimeInterval = 300 // 5 minutes

    // MARK: - Submanagers (set after init)

    private(set) var fileTransfer: FileTransfer?
    private(set) var voiceCallManager: VoiceCallManager?
    let deviceStore = DeviceRecordStore()
    let chatManager = ChatManager()
    let groupStore = DeviceGroupStore()

    // MARK: - Typing Indicator State

    private var typingDebounceTask: Task<Void, Never>?
    private var lastTypingSent: Date?

    private static let transferHistoryKey = "peerDropTransferHistory"

    init() {
        let certManager = CertificateManager()
        self.localIdentity = .local(certificateFingerprint: certManager.fingerprint)

        // Deferred init — fileTransfer needs `self`
        self.fileTransfer = FileTransfer(connectionManager: self)

        loadTransferHistory()

        // Forward chatManager changes so views observing ConnectionManager re-render on unread updates
        chatManager.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        // Screenshot mode: automatically start discovery and set up mock connection
        if ScreenshotModeProvider.shared.isActive {
            Task { @MainActor in
                self.startDiscovery()
                // Delay slightly to ensure UI has rendered discovered peers
                try? await Task.sleep(nanoseconds: 500_000_000)
                self.setupScreenshotModeConnection()
            }
        }
    }

    /// Call once after init to wire up CallKit (requires AppDelegate reference).
    func configureVoiceCalling(callKitManager: CallKitManager) {
        self.voiceCallManager = VoiceCallManager(connectionManager: self, callKitManager: callKitManager)
    }

    // MARK: - Multi-Connection Management

    /// Get a connection by peer ID.
    func connection(for peerID: String) -> PeerConnection? {
        connections[peerID]
    }

    /// Check if a peer is connected.
    func isConnected(to peerID: String) -> Bool {
        connections[peerID]?.state.isConnected ?? false
    }

    /// Focus on a specific peer connection.
    func focus(on peerID: String) {
        guard connections[peerID] != nil else { return }
        focusedPeerID = peerID
    }

    /// Add a new peer connection.
    private func addConnection(_ peerConnection: PeerConnection) {
        let peerID = peerConnection.id
        connections[peerID] = peerConnection

        // Set up callbacks
        peerConnection.onStateChange = { [weak self] newState in
            self?.handlePeerStateChange(peerID: peerID, newState: newState)
        }

        peerConnection.onMessageReceived = { [weak self] message in
            self?.handleMessage(message, from: peerID)
        }

        peerConnection.onDisconnected = { [weak self] in
            self?.handlePeerDisconnected(peerID: peerID)
        }

        // If no focused connection, focus on this one
        if focusedPeerID == nil {
            focusedPeerID = peerID
        }

        // Start receive loop
        peerConnection.startReceiving()

        objectWillChange.send()
    }

    /// Remove a peer connection.
    private func removeConnection(peerID: String) {
        connections.removeValue(forKey: peerID)

        // Update focused peer if needed
        if focusedPeerID == peerID {
            focusedPeerID = connections.keys.first
        }

        objectWillChange.send()
    }

    private func handlePeerStateChange(peerID: String, newState: PeerConnectionState) {
        objectWillChange.send()

        // Update global state based on all connections
        updateGlobalState()
    }

    private func handlePeerDisconnected(peerID: String) {
        logger.info("Peer \(peerID.prefix(8)) disconnected")

        // Clean up file transfer session if any
        if let peerConn = connections[peerID] {
            peerConn.fileTransferSession?.handleConnectionFailure()
            peerConn.voiceCallSession?.endCallLocally()
        }

        removeConnection(peerID: peerID)
        updateGlobalState()
    }

    /// Update the global ConnectionState based on all peer connections.
    private func updateGlobalState() {
        if connections.isEmpty {
            if case .discovering = state { return }
            if discoveryCoordinator != nil {
                transition(to: .discovering)
            }
            return
        }

        // If any connection is transferring, show transferring state
        if connections.values.contains(where: { $0.isTransferring }) {
            if case .transferring = state { return }
            transition(to: .transferring(progress: 0))
            return
        }

        // If any connection is in voice call, show voice call state
        if connections.values.contains(where: { $0.isInVoiceCall }) {
            if case .voiceCall = state { return }
            transition(to: .voiceCall)
            return
        }

        // If any connection is connected, show connected state
        if connections.values.contains(where: { $0.state.isConnected }) {
            if case .connected = state { return }
            transition(to: .connected)
            return
        }

        // If all connections are connecting, show connecting state
        if connections.values.allSatisfy({ $0.state == .connecting }) {
            if case .connecting = state { return }
            transition(to: .connecting)
            return
        }
    }

    private func recordConnectedDevice() {
        guard let peer = connectedPeer else { return }
        let sourceType: String
        let host: String?
        let port: UInt16?
        if let lastPeer = lastConnectedPeer {
            switch lastPeer.source {
            case .bonjour: sourceType = "bonjour"
            case .manual: sourceType = "manual"
            }
            switch lastPeer.endpoint {
            case .manual(let h, let p):
                host = h; port = p
            case .bonjour:
                host = nil; port = nil
            }
        } else {
            sourceType = "bonjour"; host = nil; port = nil
        }
        let id = lastConnectedPeer?.id ?? peer.id
        deviceStore.addOrUpdate(id: id, displayName: peer.displayName, sourceType: sourceType, host: host, port: port)
    }

    // MARK: - State Transitions

    func transition(to newState: ConnectionState) {
        let target = TransitionTarget(from: newState)
        guard state.canTransition(to: target) else {
            logger.warning("Invalid transition: \(String(describing: self.state)) → \(String(describing: newState))")
            return
        }
        let oldState = state
        logger.info("State: \(String(describing: oldState)) → \(String(describing: newState))")
        state = newState
        triggerHaptic(for: newState)

        // Heartbeat management (legacy single-connection mode)
        switch newState {
        case .connected:
            if activeConnection != nil {
                startHeartbeat()
            }
        case .disconnected, .failed, .rejected, .discovering, .idle:
            stopHeartbeat()
        default:
            break
        }
    }

    private func triggerHaptic(for newState: ConnectionState) {
        switch newState {
        case .connected:
            HapticManager.connectionAccepted()
        case .rejected:
            HapticManager.connectionRejected()
        case .failed:
            HapticManager.transferFailed()
        case .incomingRequest:
            HapticManager.incomingRequest()
        case .voiceCall:
            HapticManager.callStarted()
        default:
            break
        }
    }

    // MARK: - Discovery

    func startDiscovery() {
        // Screenshot mode: inject mock discovered peers without real network discovery
        if ScreenshotModeProvider.shared.isActive {
            startScreenshotModeDiscovery()
            return
        }

        // Tear down any lingering listener/browser first (idempotent)
        stopDiscovery()

        // Create TLS-enabled listener if we have an identity
        let tlsOpts: NWProtocolTLS.Options?
        if let identity = certificateManager.identity {
            tlsOpts = TLSConfiguration.serverOptions(identity: identity)
        } else {
            tlsOpts = nil
        }

        let bonjour = BonjourDiscovery(localPeerName: localIdentity.displayName, tlsOptions: tlsOpts)
        bonjour.onIncomingConnection = { [weak self] connection in
            Task { @MainActor in
                self?.handleIncomingConnection(connection)
            }
        }

        let coordinator = DiscoveryCoordinator(backends: [bonjour])
        coordinator.$peers
            .receive(on: DispatchQueue.main)
            .assign(to: &$discoveredPeers)

        coordinator.start()
        self.bonjourDiscovery = bonjour
        self.discoveryCoordinator = coordinator
        transition(to: .discovering)

        // Start network path monitoring
        startNetworkPathMonitor()
    }

    /// Screenshot mode: inject mock data without real network operations.
    private func startScreenshotModeDiscovery() {
        logger.info("Screenshot mode: injecting mock discovered peers")
        stopDiscovery()

        // Inject mock discovered peers
        discoveredPeers = ScreenshotModeProvider.shared.mockDiscoveredPeers

        // Inject mock device records (contacts)
        for record in ScreenshotModeProvider.shared.mockDeviceRecords {
            deviceStore.addOrUpdate(
                id: record.id,
                displayName: record.displayName,
                sourceType: record.sourceType,
                host: record.host,
                port: record.port
            )
        }

        // Inject mock transfer history
        for record in ScreenshotModeProvider.shared.mockTransferRecords {
            if !transferHistory.contains(where: { $0.id == record.id }) {
                transferHistory.append(record)
            }
        }

        transition(to: .discovering)
    }

    /// Screenshot mode: create a mock connection to simulate connected state.
    func setupScreenshotModeConnection() {
        guard ScreenshotModeProvider.shared.isActive else { return }
        logger.info("Screenshot mode: setting up mock connection")

        let mockPeer = ScreenshotModeProvider.shared.mockConnectedPeer
        let mockPeerID = ScreenshotModeProvider.mockConnectedPeerID

        // Update lastConnectedPeer for UI
        lastConnectedPeer = discoveredPeers.first { $0.id == mockPeerID }

        // Create a mock PeerConnection without real network connection
        // We use a dummy NWConnection that won't actually connect
        let dummyParams = NWParameters.tcp
        let dummyEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 1)
        let dummyConnection = NWConnection(to: dummyEndpoint, using: dummyParams)

        let peerConnection = PeerConnection(
            peerID: mockPeerID,
            connection: dummyConnection,
            peerIdentity: mockPeer,
            localIdentity: localIdentity,
            state: .connected
        )

        connections[mockPeerID] = peerConnection
        focusedPeerID = mockPeerID

        // Transition through valid state path: discovering -> peerFound -> requesting -> connecting -> connected
        transition(to: .peerFound)
        transition(to: .requesting)
        transition(to: .connecting)
        transition(to: .connected)

        logger.info("Screenshot mode: mock connection established, state = \(String(describing: self.state))")
    }

    func stopDiscovery() {
        discoveryCoordinator?.stop()
        discoveryCoordinator = nil
        bonjourDiscovery = nil
        stopNetworkPathMonitor()
    }

    // MARK: - Network Path Monitoring

    private func startNetworkPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            self?.handleNetworkPathChange(path)
        }
        monitor.start(queue: .global(qos: .utility))
        pathMonitor = monitor
    }

    private func stopNetworkPathMonitor() {
        pathMonitor?.cancel()
        pathMonitor = nil
        lastNetworkPath = nil
    }

    private nonisolated func handleNetworkPathChange(_ newPath: NWPath) {
        Task { @MainActor [weak self] in
            guard let self else { return }

            guard let lastPath = self.lastNetworkPath else {
                self.lastNetworkPath = newPath
                return
            }

            // Detect network interface changes
            let oldInterfaces = Set(lastPath.availableInterfaces.map { $0.name })
            let newInterfaces = Set(newPath.availableInterfaces.map { $0.name })

            if oldInterfaces != newInterfaces {
                self.handleNetworkInterfaceChange(from: oldInterfaces, to: newInterfaces)
            }

            self.lastNetworkPath = newPath
        }
    }

    private func handleNetworkInterfaceChange(from old: Set<String>, to new: Set<String>) {
        logger.info("Network interface changed: \(old) → \(new)")

        // WiFi switching: restart discovery for connected/transferring states
        switch state {
        case .connected, .transferring:
            statusToast = "Network changed, reconnecting..."
            restartDiscovery()
        default:
            break
        }
    }

    func restartDiscovery() {
        logger.info("restartDiscovery() called from state: \(String(describing: self.state))")
        stopDiscovery()
        // Respect the user's online/offline preference before restarting
        let defaults = UserDefaults.standard
        let isOnline = defaults.object(forKey: "peerDropIsOnline") == nil
            ? true
            : defaults.bool(forKey: "peerDropIsOnline")
        guard isOnline else {
            logger.info("restartDiscovery: user is offline, skipping")
            return
        }
        startDiscovery()
        logger.info("restartDiscovery: discovery restarted, state=\(String(describing: self.state))")
    }

    /// Clear peer info and return to discovery (used by UI "Back to Discovery" button).
    func returnToDiscovery() {
        focusedPeerID = nil
        if case .discovering = state { return }
        if discoveryCoordinator == nil {
            restartDiscovery()
        } else {
            transition(to: .discovering)
        }
    }

    func addManualPeer(host: String, port: UInt16, name: String?) {
        discoveryCoordinator?.addManualPeer(host: host, port: port, name: name)
    }

    // MARK: - Reconnect

    /// Attempt to reconnect to the last connected peer with exponential backoff.
    func reconnect() {
        guard let peer = lastConnectedPeer else { return }

        Task {
            guard let delay = await reconnectController.nextDelay() else {
                await MainActor.run {
                    self.statusToast = "Max reconnection attempts reached"
                }
                return
            }

            let attempt = await reconnectController.currentAttempt
            logger.info("Reconnecting (attempt \(attempt)) after \(String(format: "%.1f", delay))s delay")

            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

            await MainActor.run {
                self.requestConnection(to: peer)
            }
        }
    }

    /// Reset reconnect attempts (call on successful connection).
    private func resetReconnectAttempts() {
        Task { await reconnectController.reset() }
    }

    // MARK: - Circuit Breaker

    /// Check if a connection attempt should be made to the given peer.
    /// Returns `false` if the circuit breaker is open (too many recent failures).
    func shouldAttemptConnection(to peerID: String) -> Bool {
        guard let failure = failedPeers[peerID] else { return true }

        if failure.count >= circuitBreakerThreshold {
            let elapsed = Date().timeIntervalSince(failure.lastFailed)
            let cooldown = self.circuitBreakerCooldown
            if elapsed < cooldown {
                logger.info("Circuit breaker open for peer \(peerID.prefix(8)): \(failure.count) failures, \(Int(cooldown - elapsed))s remaining")
                return false // Circuit breaker is open
            }
            // Cooldown period has passed, reset
            failedPeers.removeValue(forKey: peerID)
        }
        return true
    }

    /// Record a connection failure for the given peer.
    func recordConnectionFailure(for peerID: String) {
        var failure = failedPeers[peerID] ?? (count: 0, lastFailed: Date())
        failure.count += 1
        failure.lastFailed = Date()
        failedPeers[peerID] = failure
        logger.info("Connection failure recorded for peer \(peerID.prefix(8)): \(failure.count) failures")
    }

    /// Record a successful connection, resetting the failure count.
    func recordConnectionSuccess(for peerID: String) {
        if failedPeers.removeValue(forKey: peerID) != nil {
            logger.info("Circuit breaker reset for peer \(peerID.prefix(8))")
        }
    }

    /// Attempt to reconnect to a specific peer.
    func reconnect(to peerID: String) {
        if let peer = discoveredPeers.first(where: { $0.id == peerID }) {
            requestConnection(to: peer)
        } else if let record = deviceStore.records.first(where: { $0.id == peerID }),
                  let host = record.host, let port = record.port {
            addManualPeer(host: host, port: port, name: record.displayName)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                if let peer = self?.discoveredPeers.first(where: { $0.id == peerID }) {
                    self?.requestConnection(to: peer)
                }
            }
        }
    }

    /// Whether a reconnect is possible (we have a last-connected peer).
    var canReconnect: Bool {
        lastConnectedPeer != nil
    }

    // MARK: - App Lifecycle

    func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .active:
            endBackgroundTask()
            // Restart discovery when returning to foreground
            switch state {
            case .idle:
                restartDiscovery()
            case .discovering:
                restartDiscovery()
            case .connected, .transferring, .voiceCall:
                // Connection should still be alive, but restart discovery for peer browsing
                // Don't call stopDiscovery first - just restart the browser
                if bonjourDiscovery == nil {
                    restartDiscovery()
                }
            case .failed, .disconnected:
                // Connection was lost while in background, restart discovery
                restartDiscovery()
            default:
                break
            }
        case .background:
            // Flush pending writes before entering background
            deviceStore.saveImmediately()
            chatManager.flushAllPendingPersists()
            // Keep connection alive in background for active connection states
            switch state {
            case .connected, .transferring, .voiceCall:
                beginBackgroundTask()
                // Keep heartbeat running but stop discovery to save power
                stopDiscoveryOnly()
            case .requesting, .connecting, .incomingRequest:
                // Need background time to complete handshake
                beginBackgroundTask()
                stopDiscoveryOnly()
            default:
                stopDiscovery()
            }
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    /// Stop only the discovery (browser/listener) but keep the active connection.
    private func stopDiscoveryOnly() {
        bonjourDiscovery?.stopDiscovery()
        bonjourDiscovery = nil
        discoveryCoordinator?.stop()
        discoveryCoordinator = nil
        // Don't clear discoveredPeers - we might need them when returning
    }

    private func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.handleBackgroundExpiration()
        }

        // Start monitoring remaining background time
        startBackgroundTimeMonitor()
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        stopBackgroundTimeMonitor()
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    private func startBackgroundTimeMonitor() {
        backgroundTimeMonitorTask?.cancel()
        backgroundTimeMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000) // Check every 2 seconds

                guard let self, !Task.isCancelled else { break }
                let remaining = UIApplication.shared.backgroundTimeRemaining

                if remaining < self.backgroundWarningThreshold && remaining > 0 {
                    await MainActor.run {
                        self.handleBackgroundTimeWarning(remaining: remaining)
                    }
                }
            }
        }
    }

    private func stopBackgroundTimeMonitor() {
        backgroundTimeMonitorTask?.cancel()
        backgroundTimeMonitorTask = nil
    }

    private func handleBackgroundTimeWarning(remaining: TimeInterval) {
        if case .transferring = state {
            statusToast = "App will suspend soon, transfer may be interrupted"
            logger.warning("Background time remaining: \(String(format: "%.1f", remaining))s")
        }
    }

    private func handleBackgroundExpiration() {
        logger.warning("Background task expiring, disconnecting gracefully")

        // Gracefully close all connections
        Task {
            for (_, connection) in connections {
                await connection.disconnect()
            }
        }

        // Also close legacy active connection
        activeConnection?.cancel()
        activeConnection = nil

        endBackgroundTask()
    }

    // MARK: - Timeout Helpers

    private func cancelTimeouts() {
        requestingTimeoutTask?.cancel()
        requestingTimeoutTask = nil
        connectingTimeoutTask?.cancel()
        connectingTimeoutTask = nil
    }

    // MARK: - Heartbeat Keepalive

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        let generation = connectionGeneration
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
                    guard let self, !Task.isCancelled, self.connectionGeneration == generation else { return }
                    // Send ping in connected or voiceCall states (not during file transfer)
                    switch self.state {
                    case .connected, .voiceCall:
                        let ping = PeerMessage.ping(senderID: self.localIdentity.id)
                        do {
                            try await self.sendMessage(ping)
                        } catch {
                            logger.warning("Heartbeat ping failed: \(error.localizedDescription)")
                        }
                    default:
                        continue
                    }
                } catch {
                    // Task cancelled or sleep interrupted
                    return
                }
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    private func startRequestingTimeout(generation: UUID? = nil) {
        requestingTimeoutTask?.cancel()
        let gen = generation ?? connectionGeneration
        requestingTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 15_000_000_000) // 15 seconds
                guard let self, !Task.isCancelled, self.connectionGeneration == gen else { return }
                if case .requesting = self.state {
                    logger.warning("Connection request timed out after 15s")
                    // Notify the acceptor so they can dismiss the consent sheet
                    if let conn = self.activeConnection {
                        let cancel = PeerMessage.connectionCancel(senderID: self.localIdentity.id)
                        do {
                            try await conn.sendMessage(cancel)
                        } catch {
                            logger.warning("Failed to send timeout cancel to peer: \(error.localizedDescription)")
                        }
                        conn.cancel()
                    }
                    self.activeConnection = nil
                    self.transition(to: .failed(reason: "Connection timed out"))
                    if self.discoveryCoordinator == nil {
                        self.restartDiscovery()
                    }
                }
            } catch {
                // Task was cancelled, nothing to do
            }
        }
    }

    private func startConnectingTimeout(generation: UUID? = nil) {
        connectingTimeoutTask?.cancel()
        let gen = generation ?? connectionGeneration
        connectingTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
                guard let self, !Task.isCancelled, self.connectionGeneration == gen else { return }
                if case .connecting = self.state {
                    logger.warning("Connection setup timed out after 10s")
                    // Notify the acceptor so they can dismiss the consent sheet
                    if let conn = self.activeConnection {
                        let cancel = PeerMessage.connectionCancel(senderID: self.localIdentity.id)
                        do {
                            try await conn.sendMessage(cancel)
                        } catch {
                            logger.warning("Failed to send setup timeout cancel to peer: \(error.localizedDescription)")
                        }
                        conn.cancel()
                    }
                    self.activeConnection = nil
                    self.transition(to: .failed(reason: "Connection setup timed out"))
                    if self.discoveryCoordinator == nil {
                        self.restartDiscovery()
                    }
                }
            } catch {
                // Task was cancelled, nothing to do
            }
        }
    }

    // MARK: - Connection Request (Outgoing)

    func requestConnection(to peer: DiscoveredPeer) {
        // Check if already connected to this peer
        if let existingConn = connections[peer.id], existingConn.state.isConnected {
            // Just focus on this connection
            focusedPeerID = peer.id
            return
        }

        // Check circuit breaker
        guard shouldAttemptConnection(to: peer.id) else {
            statusToast = "Connection temporarily blocked (too many failures)"
            return
        }

        // Check if we've reached max connections
        if activeConnectionCount >= maxConnections {
            statusToast = "Maximum connections reached (\(maxConnections))"
            return
        }

        // Guard against duplicate requests (double-tap, rapid Reconnect)
        switch state {
        case .requesting, .connecting:
            logger.info("requestConnection ignored — already in \(String(describing: self.state))")
            return
        default:
            break
        }

        lastConnectedPeer = peer
        cancelTimeouts()

        // Cancel any previous connection and bump generation
        let oldConnection = activeConnection
        activeConnection = nil
        oldConnection?.cancel()
        let generation = UUID()
        connectionGeneration = generation

        // Normalize state so we can reach .requesting
        switch state {
        case .disconnected, .failed, .rejected, .idle:
            transition(to: .discovering)
        default:
            break
        }
        if case .discovering = state {
            transition(to: .peerFound)
        }
        transition(to: .requesting)

        let endpoint: NWEndpoint
        switch peer.endpoint {
        case .bonjour(let name, let type, let domain):
            endpoint = .service(name: name, type: type, domain: domain, interface: nil)
            logger.info("Connecting to Bonjour peer: \(name).\(type).\(domain)")
        case .manual(let host, let port):
            endpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
            logger.info("Connecting to manual peer: \(host):\(port)")
        }

        // Use TLS for outgoing connections only if we have an identity
        let clientTLS: NWProtocolTLS.Options?
        if let identity = certificateManager.identity {
            clientTLS = TLSConfiguration.clientOptions(identity: identity)
            logger.info("Using TLS for outgoing connection")
        } else {
            clientTLS = nil
            logger.info("No TLS identity available, connecting without TLS")
        }
        let params = NWParameters.peerDrop(tls: clientTLS)
        let connection = NWConnection(to: endpoint, using: params)

        connection.stateUpdateHandler = { [weak self] nwState in
            logger.info("NWConnection state: \(String(describing: nwState))")
            Task { @MainActor in
                guard let self, self.connectionGeneration == generation else { return }
                self.handleConnectionStateChange(nwState)
            }
        }

        connection.start(queue: .global(qos: .userInitiated))
        activeConnection = connection

        startRequestingTimeout(generation: generation)

        Task {
            do {
                logger.info("Waiting for connection to be ready...")
                try await connection.waitReady()
                logger.info("Connection ready! Sending HELLO...")
                let hello = try PeerMessage.hello(identity: localIdentity)
                try await connection.sendMessage(hello)
                logger.info("HELLO sent. Sending CONNECTION_REQUEST...")
                let request = PeerMessage.connectionRequest(senderID: localIdentity.id)
                try await connection.sendMessage(request)
                logger.info("CONNECTION_REQUEST sent. Starting receive loop.")
                startReceiving()
            } catch {
                logger.error("Connection failed: \(userFriendlyErrorMessage(error))")
                cancelTimeouts()
                activeConnection?.cancel()
                activeConnection = nil
                recordConnectionFailure(for: peer.id)
                transition(to: .failed(reason: userFriendlyErrorMessage(error)))
                if discoveryCoordinator == nil {
                    restartDiscovery()
                }
            }
        }
    }

    // MARK: - Incoming Connection

    private func handleIncomingConnection(_ connection: NWConnection) {
        logger.info("Incoming connection from: \(String(describing: connection.endpoint))")

        // If already showing consent sheet for another request, reject this one
        if pendingIncomingRequest != nil {
            logger.info("Already showing consent sheet, rejecting incoming from: \(String(describing: connection.endpoint))")
            connection.cancel()
            return
        }

        // Check if we've reached max connections (for multi-connection mode)
        if activeConnectionCount >= maxConnections {
            logger.info("Max connections reached, rejecting incoming from: \(String(describing: connection.endpoint))")
            connection.cancel()
            return
        }

        // Track if we have an outgoing connection attempt (for simultaneous connect handling)
        let hadOutgoingConnection = activeConnection != nil && state == .requesting

        // Start the incoming connection to receive HELLO and determine peer identity
        connection.start(queue: .global(qos: .userInitiated))

        connection.stateUpdateHandler = { [weak self] nwState in
            logger.info("Incoming NWConnection state: \(String(describing: nwState))")
            Task { @MainActor in
                guard let self else { return }
                switch nwState {
                case .failed, .cancelled:
                    if self.pendingIncomingRequest?.connection === connection {
                        self.pendingIncomingRequest = nil
                        self.statusToast = "Connection request expired"
                    }
                    // Clean up if this was the active connection
                    if self.activeConnection === connection {
                        self.activeConnection = nil
                        switch self.state {
                        case .incomingRequest, .connecting:
                            self.transition(to: .discovering)
                        default:
                            break
                        }
                    }
                default:
                    break
                }
            }
        }

        Task {
            do {
                logger.info("Waiting for incoming connection to be ready...")
                try await connection.waitReady()
                logger.info("Incoming connection ready! Waiting for HELLO...")
                let helloMsg = try await connection.receiveMessage()
                logger.info("Received message type: \(String(describing: helloMsg.type))")

                guard helloMsg.type == .hello, helloMsg.version == .current,
                      let payload = helloMsg.payload else {
                    logger.error("Incompatible protocol version or invalid hello")
                    connection.cancel()
                    return
                }

                let peerIdentity = try JSONDecoder().decode(PeerIdentity.self, from: payload)
                logger.info("Peer identity received: \(peerIdentity.displayName)")

                // Check if already connected to this peer
                if connections[peerIdentity.id]?.state.isConnected == true {
                    logger.info("Already connected to this peer, rejecting duplicate")
                    connection.cancel()
                    return
                }

                // Handle simultaneous connection attempts using peer ID comparison
                // The peer with the larger ID becomes the initiator (keeps outgoing)
                // The peer with the smaller ID becomes the acceptor (accepts incoming)
                if hadOutgoingConnection || (activeConnection != nil && state == .requesting) {
                    let localID = localIdentity.id
                    let peerID = peerIdentity.id

                    if localID > peerID {
                        // We have larger ID -> we are the initiator, reject this incoming
                        logger.info("Simultaneous connect: local ID > peer ID, rejecting incoming (we are initiator)")
                        connection.cancel()
                        return
                    } else {
                        // We have smaller ID -> we are the acceptor, cancel our outgoing and accept this
                        logger.info("Simultaneous connect: local ID < peer ID, cancelling outgoing (we are acceptor)")
                        cancelTimeouts()
                        let oldConnection = activeConnection
                        activeConnection = nil
                        oldConnection?.cancel()
                        connectionGeneration = UUID()
                    }
                }

                // Now accept this as the active connection
                activeConnection = connection

                let requestMsg = try await connection.receiveMessage()

                guard requestMsg.type == .connectionRequest else {
                    logger.error("Expected connectionRequest, got: \(String(describing: requestMsg.type))")
                    connection.cancel()
                    activeConnection = nil
                    return
                }

                logger.info("Connection request received! Showing consent sheet.")
                // Normalize state so .incomingRequest transition is valid
                switch state {
                case .disconnected, .failed, .rejected, .idle:
                    transition(to: .discovering)
                default:
                    break
                }
                transition(to: .incomingRequest)
                NotificationManager.shared.postIncomingConnection(from: peerIdentity.displayName)
                pendingIncomingRequest = IncomingRequest(
                    peerIdentity: peerIdentity,
                    connection: connection
                )
                // Monitor for connectionCancel or connection death while consent sheet is showing
                startConsentMonitor(on: connection)
            } catch {
                logger.error("Incoming connection error: \(error.localizedDescription)")
                connection.cancel()
                if activeConnection === connection {
                    activeConnection = nil
                }
                if case .incomingRequest = state {
                    transition(to: .discovering)
                }
            }
        }
    }

    /// Listens for messages (e.g. connectionCancel) while the consent sheet is showing.
    /// Without active reads, NWConnection won't detect remote close promptly.
    private func startConsentMonitor(on connection: NWConnection) {
        let generation = connectionGeneration

        // Cancel any existing monitors
        consentMonitorTask?.cancel()
        consentTimeoutTask?.cancel()

        // Start connection monitor
        consentMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.pendingIncomingRequest != nil else { break }
                do {
                    let message = try await connection.receiveMessage()
                    // Process the message on the main actor
                    await MainActor.run {
                        self.handleMessage(message, from: message.senderID)
                    }
                } catch {
                    // Read failed — connection died while consent was showing
                    await MainActor.run {
                        if self.pendingIncomingRequest != nil {
                            logger.info("Consent monitor: connection lost, dismissing consent sheet")
                            self.pendingIncomingRequest = nil
                            self.activeConnection = nil
                            self.statusToast = "Connection request expired"
                            self.transition(to: .discovering)
                        }
                    }
                    break
                }
            }
        }

        // Start consent timeout
        consentTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: (self?.consentTimeoutSeconds ?? 30) * 1_000_000_000)
                guard let self, !Task.isCancelled,
                      self.connectionGeneration == generation,
                      self.pendingIncomingRequest != nil else { return }

                await MainActor.run {
                    logger.info("Consent timeout: auto-rejecting after \(self.consentTimeoutSeconds)s")
                    self.statusToast = "Connection request timed out"
                    self.pendingIncomingRequest = nil
                    connection.cancel()
                    self.activeConnection = nil
                    self.transition(to: .discovering)
                }
            } catch {
                // Task cancelled - expected on accept/reject
            }
        }
    }

    // MARK: - Consent Response

    func acceptConnection() {
        guard let request = pendingIncomingRequest else { return }
        // Cancel consent monitoring and timeout
        consentMonitorTask?.cancel()
        consentMonitorTask = nil
        consentTimeoutTask?.cancel()
        consentTimeoutTask = nil
        // Verify the connection is still alive before attempting to accept
        guard request.connection.state == .ready else {
            pendingIncomingRequest = nil
            activeConnection = nil
            statusToast = "Connection is no longer available"
            transition(to: .discovering)
            return
        }
        pendingIncomingRequest = nil

        let peerIdentity = request.peerIdentity
        let peerID = peerIdentity.id

        // Create PeerConnection for multi-connection support
        let peerConnection = PeerConnection(
            peerID: peerID,
            connection: request.connection,
            peerIdentity: peerIdentity,
            localIdentity: localIdentity,
            state: .connecting
        )

        // Set lastConnectedPeer by finding the matching discovered peer
        if let matchingPeer = discoveredPeers.first(where: { $0.id == peerID }) {
            lastConnectedPeer = matchingPeer
        }

        // Normalize state so .connecting transition is valid from any terminal state
        switch state {
        case .disconnected, .failed, .rejected, .idle:
            transition(to: .discovering)
            transition(to: .incomingRequest)
        case .incomingRequest:
            break // already correct
        default:
            break
        }
        transition(to: .connecting)
        startConnectingTimeout()

        Task {
            do {
                let accept = PeerMessage.connectionAccept(senderID: localIdentity.id)
                try await request.connection.sendMessage(accept)
                let hello = try PeerMessage.hello(identity: localIdentity)
                try await request.connection.sendMessage(hello)
                cancelTimeouts()

                // Update PeerConnection state and add to connections
                peerConnection.updateState(.connected)
                addConnection(peerConnection)

                // Also maintain legacy single-connection for backward compatibility
                focusedPeerID = peerID

                transition(to: .connected)
                recordConnectedDevice()
                resetReconnectAttempts()
                recordConnectionSuccess(for: peerID)
            } catch {
                cancelTimeouts()
                activeConnection?.cancel()
                activeConnection = nil
                recordConnectionFailure(for: peerID)
                transition(to: .failed(reason: userFriendlyErrorMessage(error)))
                if discoveryCoordinator == nil {
                    restartDiscovery()
                }
            }
        }
    }

    func rejectConnection() {
        guard let request = pendingIncomingRequest else { return }
        // Cancel consent monitoring and timeout
        consentMonitorTask?.cancel()
        consentMonitorTask = nil
        consentTimeoutTask?.cancel()
        consentTimeoutTask = nil
        pendingIncomingRequest = nil

        Task {
            let reject = PeerMessage.connectionReject(senderID: localIdentity.id)
            do {
                try await request.connection.sendMessage(reject)
            } catch {
                logger.warning("Failed to send rejection to peer: \(error.localizedDescription)")
            }
            request.connection.cancel()
            activeConnection = nil
            statusToast = "Connection declined"
            if discoveryCoordinator == nil {
                restartDiscovery()
            } else {
                transition(to: .discovering)
            }
        }
    }

    func disconnect() {
        logger.info("disconnect() called — state=\(String(describing: self.state)), activeConnection=\(self.activeConnection != nil ? "exists" : "nil")")
        cancelTimeouts()
        connectionGeneration = UUID()
        // Capture and nil-out the connection BEFORE cancelling so the receive
        // loop sees activeConnection == nil and doesn't race to .failed.
        let connection = activeConnection
        activeConnection = nil
        Task {
            if let connection {
                let msg = PeerMessage.disconnect(senderID: localIdentity.id)
                do {
                    try await connection.sendMessage(msg)
                } catch {
                    logger.warning("Failed to send disconnect message: \(error.localizedDescription)")
                }
                connection.cancel()
            }
            cleanupAfterDisconnect()
        }
    }

    /// Disconnect from a specific peer.
    func disconnect(from peerID: String) async {
        guard let peerConn = connections[peerID] else { return }
        await peerConn.disconnect()
        removeConnection(peerID: peerID)
        updateGlobalState()
    }

    /// Disconnect from all peers.
    func disconnectAll() async {
        for (peerID, peerConn) in connections {
            await peerConn.disconnect()
            removeConnection(peerID: peerID)
        }
        cleanupAfterDisconnect()
    }

    /// Cleanup after the local user initiates disconnect.
    private func cleanupAfterDisconnect() {
        activeConnection = nil
        focusedPeerID = nil
        endBackgroundTask()
        transition(to: .disconnected)
        // Auto-resume discovery so the user returns to the Nearby tab seamlessly.
        // Avoid full restart when the coordinator already exists — stopping the
        // Bonjour listener causes this device to temporarily vanish from peers.
        if discoveryCoordinator == nil {
            restartDiscovery()
        } else {
            transition(to: .discovering)
        }
    }

    // MARK: - Message Receive Loop

    private func startReceiving() {
        guard let connection = activeConnection else {
            logger.warning("startReceiving: no activeConnection!")
            return
        }
        let generation = connectionGeneration
        logger.info("Entering receive loop (gen=\(generation.uuidString.prefix(8)))")

        Task {
            while activeConnection != nil && connectionGeneration == generation {
                do {
                    let message = try await connection.receiveMessage()
                    // Verify this loop still owns the connection
                    guard connectionGeneration == generation else { break }
                    handleMessage(message, from: message.senderID)
                } catch {
                    logger.error("Receive loop error: \(userFriendlyErrorMessage(error))")
                    // Only handle if this loop still owns the connection
                    guard connectionGeneration == generation, activeConnection != nil else { break }
                    fileTransfer?.handleConnectionFailure()
                    activeConnection = nil
                    // Keep connectedPeer so UI shows who we lost connection with
                    transition(to: .failed(reason: userFriendlyErrorMessage(error)))
                    if discoveryCoordinator == nil {
                        restartDiscovery()
                    }
                    break
                }
            }
        }
    }

    private func handleMessage(_ message: PeerMessage, from senderID: String) {
        logger.info("handleMessage: \(String(describing: message.type)) from \(senderID)")

        // Route to specific peer connection if it exists
        if let peerConn = connections[senderID] {
            handleMessageForPeer(message, peerConnection: peerConn)
            return
        }

        // Fall back to legacy single-connection handling
        handleMessageLegacy(message)
    }

    /// Handle message for a specific peer connection.
    private func handleMessageForPeer(_ message: PeerMessage, peerConnection: PeerConnection) {
        let peerID = peerConnection.id

        switch message.type {
        case .disconnect:
            peerConnection.updateState(.disconnected)
            peerConnection.fileTransferSession?.handleConnectionFailure()
            peerConnection.voiceCallSession?.endCallLocally()
            removeConnection(peerID: peerID)
            updateGlobalState()

        case .fileOffer:
            guard FeatureSettings.isFileTransferEnabled else {
                let reject = PeerMessage.fileReject(senderID: localIdentity.id, reason: "featureDisabled")
                Task {
                    do { try await peerConnection.sendMessage(reject) }
                    catch { logger.warning("Failed to send file reject: \(error.localizedDescription)") }
                }
                return
            }
            // Create or get file transfer session
            if peerConnection.fileTransferSession == nil {
                let session = FileTransferSession(peerID: peerID)
                session.sendMessage = { [weak peerConnection] msg in
                    try await peerConnection?.sendMessage(msg)
                }
                peerConnection.fileTransferSession = session
            }
            peerConnection.fileTransferSession?.handleFileOffer(message)
            peerConnection.setTransferring(true)
            showTransferProgress = true
            updateGlobalState()

        case .fileAccept:
            peerConnection.fileTransferSession?.handleFileAccept()

        case .fileReject:
            let reason = (try? message.decodePayload(RejectionPayload.self))?.reason
            peerConnection.fileTransferSession?.handleFileReject(reason: reason)
            peerConnection.setTransferring(false)
            updateGlobalState()

        case .fileChunk:
            peerConnection.fileTransferSession?.handleFileChunk(message)

        case .fileComplete:
            if let record = peerConnection.fileTransferSession?.handleFileComplete(message) {
                transferHistory.insert(record, at: 0)
                latestToast = record
            }
            peerConnection.setTransferring(false)
            showTransferProgress = false
            updateGlobalState()

        case .callRequest:
            guard FeatureSettings.isVoiceCallEnabled else {
                let reject = PeerMessage.callReject(senderID: localIdentity.id, reason: "featureDisabled")
                Task {
                    do { try await peerConnection.sendMessage(reject) }
                    catch { logger.warning("Failed to send call reject: \(error.localizedDescription)") }
                }
                return
            }
            voiceCallManager?.handleCallRequest(from: message.senderID)

        case .callAccept:
            voiceCallManager?.handleCallAccept()

        case .callReject:
            let reason = (try? message.decodePayload(RejectionPayload.self))?.reason
            voiceCallManager?.handleCallReject(reason: reason)

        case .callEnd:
            voiceCallManager?.handleCallEnd()

        case .sdpOffer, .sdpAnswer, .iceCandidate:
            voiceCallManager?.handleSignaling(message)

        case .textMessage:
            guard FeatureSettings.isChatEnabled else {
                let reject = PeerMessage.chatReject(senderID: localIdentity.id, reason: "featureDisabled")
                Task {
                    do { try await peerConnection.sendMessage(reject) }
                    catch { logger.warning("Failed to send chat reject: \(error.localizedDescription)") }
                }
                return
            }
            guard let payload = try? message.decodePayload(TextMessagePayload.self) else {
                logger.warning("Failed to decode TextMessagePayload")
                return
            }
            // Determine the storage key: groupID for group messages, peerID for 1-to-1
            let storageKey = payload.groupID ?? peerID
            let savedMsg = chatManager.saveIncoming(
                text: payload.text,
                peerID: storageKey,
                peerName: peerConnection.peerIdentity.displayName,
                groupID: payload.groupID,
                senderID: payload.groupID != nil ? message.senderID : nil,
                senderName: payload.senderName,
                replyToMessageID: payload.replyToMessageID,
                replyToText: payload.replyToText,
                replyToSenderName: payload.replyToSenderName
            )
            NotificationManager.shared.postChatMessage(from: peerConnection.peerIdentity.displayName, text: payload.text)
            sendDeliveryReceipt(for: savedMsg.id, to: peerConnection, groupID: payload.groupID)

        case .mediaMessage:
            guard FeatureSettings.isChatEnabled else {
                let reject = PeerMessage.chatReject(senderID: localIdentity.id, reason: "featureDisabled")
                Task {
                    do { try await peerConnection.sendMessage(reject) }
                    catch { logger.warning("Failed to send chat reject: \(error.localizedDescription)") }
                }
                return
            }
            guard let payload = try? message.decodePayload(MediaMessagePayload.self) else {
                logger.warning("Failed to decode MediaMessagePayload")
                return
            }
            chatManager.saveIncomingMedia(
                payload: payload,
                fileData: Data(),
                peerID: peerID,
                peerName: peerConnection.peerIdentity.displayName
            )
            NotificationManager.shared.postChatMessage(from: peerConnection.peerIdentity.displayName, text: payload.fileName)

        case .messageReceipt:
            guard let payload = try? message.decodePayload(MessageReceiptPayload.self) else {
                logger.warning("Failed to decode MessageReceiptPayload")
                return
            }
            // Check if this is a group receipt
            if let groupID = payload.groupID, let senderID = payload.senderID {
                // Group message receipt - update per-member status
                for msgID in payload.messageIDs {
                    if payload.receiptType == .read {
                        chatManager.markGroupMessageRead(messageID: msgID, groupID: groupID, by: senderID)
                    } else {
                        chatManager.markGroupMessageDelivered(messageID: msgID, groupID: groupID, to: senderID)
                    }
                }
            } else {
                // 1-to-1 message receipt
                let newStatus: MessageStatus = payload.receiptType == .read ? .read : .delivered
                for msgID in payload.messageIDs {
                    chatManager.updateStatus(messageID: msgID, status: newStatus)
                }
            }

        case .typingIndicator:
            guard let payload = try? message.decodePayload(TypingIndicatorPayload.self) else {
                logger.warning("Failed to decode TypingIndicatorPayload")
                return
            }
            chatManager.setTyping(payload.isTyping, for: peerID)

        case .reaction:
            guard let payload = try? message.decodePayload(ReactionPayload.self) else {
                logger.warning("Failed to decode ReactionPayload")
                return
            }
            switch payload.action {
            case .add:
                chatManager.addReaction(emoji: payload.emoji, to: payload.messageID, from: message.senderID)
            case .remove:
                chatManager.removeReaction(emoji: payload.emoji, from: payload.messageID, by: message.senderID)
            }

        case .chatReject:
            let reason = (try? message.decodePayload(RejectionPayload.self))?.reason // P1: rejection reason is optional, nil is acceptable
            let errorText = reason == "featureDisabled" ? "Peer has chat disabled" : "Message rejected"
            chatManager.markLastOutgoingAsFailed(peerID: peerID, errorText: errorText)

        case .ping:
            let pong = PeerMessage.pong(senderID: localIdentity.id)
            Task {
                do { try await peerConnection.sendMessage(pong) }
                catch { logger.warning("Failed to send pong: \(error.localizedDescription)") }
            }

        case .pong:
            logger.debug("Heartbeat pong received from \(peerID)")

        default:
            break
        }
    }

    /// Legacy message handling for backward compatibility.
    private func handleMessageLegacy(_ message: PeerMessage) {
        switch message.type {
        case .connectionAccept:
            // Only process if we're still waiting for acceptance
            guard case .requesting = state else {
                logger.info("Received connectionAccept but not in requesting state, sending cancel")
                let cancel = PeerMessage.connectionCancel(senderID: localIdentity.id)
                Task { [weak self] in
                    do { try await self?.sendMessage(cancel) }
                    catch { logger.warning("Failed to send connection cancel: \(error.localizedDescription)") }
                }
                return
            }
            cancelTimeouts()

            var peerIdentity: PeerIdentity?
            if let payload = message.payload,
               let identity = try? JSONDecoder().decode(PeerIdentity.self, from: payload) {
                peerIdentity = identity
            }

            // Create PeerConnection for the accepted connection
            if let identity = peerIdentity, let conn = activeConnection {
                let peerConnection = PeerConnection(
                    peerID: identity.id,
                    connection: conn,
                    peerIdentity: identity,
                    localIdentity: localIdentity,
                    state: .connected
                )
                addConnection(peerConnection)
                focusedPeerID = identity.id
            }

            // State machine requires requesting → connecting → connected
            transition(to: .connecting)
            transition(to: .connected)
            recordConnectedDevice()
            resetReconnectAttempts()
            if let identity = peerIdentity {
                recordConnectionSuccess(for: identity.id)
            }

        case .connectionReject:
            cancelTimeouts()
            activeConnection?.cancel()
            activeConnection = nil
            transition(to: .rejected)

        case .connectionCancel:
            // Initiator cancelled the request — dismiss consent sheet and clean up
            pendingIncomingRequest = nil
            cancelTimeouts()
            activeConnection?.cancel()
            activeConnection = nil
            statusToast = "Connection request was cancelled"
            // Recover from any intermediate state
            switch state {
            case .incomingRequest, .connecting:
                transition(to: .discovering)
            case .requesting:
                // We were requesting, but somehow got a cancel (simultaneous connect edge case)
                transition(to: .failed(reason: "Connection cancelled"))
                if discoveryCoordinator == nil {
                    restartDiscovery()
                }
            default:
                break
            }

        case .disconnect:
            activeConnection?.cancel()
            activeConnection = nil
            endBackgroundTask()
            fileTransfer?.handleConnectionFailure()
            voiceCallManager?.handleCallEnd()
            // Keep connectedPeer so the UI shows who disconnected.
            // Transition to .failed so the error alert offers Reconnect / Back to Discovery.
            transition(to: .failed(reason: "Peer disconnected"))
            if discoveryCoordinator == nil {
                restartDiscovery()
            }

        case .fileOffer:
            guard FeatureSettings.isFileTransferEnabled else {
                let reject = PeerMessage.fileReject(senderID: localIdentity.id, reason: "featureDisabled")
                Task { [weak self] in
                    do { try await self?.sendMessage(reject) }
                    catch { logger.warning("Failed to send file reject: \(error.localizedDescription)") }
                }
                return
            }
            fileTransfer?.handleFileOffer(message)

        case .fileAccept:
            fileTransfer?.handleFileAccept()

        case .fileReject:
            let reason = (try? message.decodePayload(RejectionPayload.self))?.reason
            fileTransfer?.handleFileReject(reason: reason)

        case .fileChunk:
            fileTransfer?.handleFileChunk(message)

        case .fileComplete:
            fileTransfer?.handleFileComplete(message)

        case .callRequest:
            guard FeatureSettings.isVoiceCallEnabled else {
                let reject = PeerMessage.callReject(senderID: localIdentity.id, reason: "featureDisabled")
                Task { [weak self] in
                    do { try await self?.sendMessage(reject) }
                    catch { logger.warning("Failed to send call reject: \(error.localizedDescription)") }
                }
                return
            }
            voiceCallManager?.handleCallRequest(from: message.senderID)

        case .callAccept:
            voiceCallManager?.handleCallAccept()

        case .callReject:
            let reason = (try? message.decodePayload(RejectionPayload.self))?.reason
            voiceCallManager?.handleCallReject(reason: reason)

        case .callEnd:
            voiceCallManager?.handleCallEnd()

        case .sdpOffer, .sdpAnswer, .iceCandidate:
            voiceCallManager?.handleSignaling(message)

        case .textMessage:
            guard FeatureSettings.isChatEnabled else {
                let reject = PeerMessage.chatReject(senderID: localIdentity.id, reason: "featureDisabled")
                Task { [weak self] in
                    do { try await self?.sendMessage(reject) }
                    catch { logger.warning("Failed to send chat reject: \(error.localizedDescription)") }
                }
                return
            }
            guard let payload = try? message.decodePayload(TextMessagePayload.self) else {
                logger.warning("Failed to decode TextMessagePayload")
                return
            }
            chatManager.saveIncoming(
                text: payload.text,
                peerID: message.senderID,
                peerName: connectedPeer?.displayName ?? "Unknown",
                replyToMessageID: payload.replyToMessageID,
                replyToText: payload.replyToText,
                replyToSenderName: payload.replyToSenderName
            )
            NotificationManager.shared.postChatMessage(from: connectedPeer?.displayName ?? "Unknown", text: payload.text)

        case .mediaMessage:
            guard FeatureSettings.isChatEnabled else {
                let reject = PeerMessage.chatReject(senderID: localIdentity.id, reason: "featureDisabled")
                Task { [weak self] in
                    do { try await self?.sendMessage(reject) }
                    catch { logger.warning("Failed to send chat reject: \(error.localizedDescription)") }
                }
                return
            }
            guard let payload = try? message.decodePayload(MediaMessagePayload.self) else {
                logger.warning("Failed to decode MediaMessagePayload")
                return
            }
            chatManager.saveIncomingMedia(
                payload: payload,
                fileData: Data(),
                peerID: message.senderID,
                peerName: connectedPeer?.displayName ?? "Unknown"
            )
            NotificationManager.shared.postChatMessage(from: connectedPeer?.displayName ?? "Unknown", text: payload.fileName)

        case .chatReject:
            // Remote peer has chat disabled — mark last outgoing message as failed
            if let peerID = connectedPeer?.id {
                let reason = (try? message.decodePayload(RejectionPayload.self))?.reason // P1: rejection reason is optional, nil is acceptable
                let errorText = reason == "featureDisabled" ? "Peer has chat disabled" : "Message rejected"
                chatManager.markLastOutgoingAsFailed(peerID: peerID, errorText: errorText)
            }

        case .hello:
            // During handshake, hello is handled inline. In the receive loop,
            // the acceptor sends a second hello after connectionAccept to share identity.
            if let payload = message.payload,
               let identity = try? JSONDecoder().decode(PeerIdentity.self, from: payload) {
                // Update or create PeerConnection
                if let peerConn = connections[identity.id] {
                    peerConn.updatePeerIdentity(identity)
                } else if focusedPeerID == nil, let conn = activeConnection {
                    let peerConnection = PeerConnection(
                        peerID: identity.id,
                        connection: conn,
                        peerIdentity: identity,
                        localIdentity: localIdentity,
                        state: .connected
                    )
                    addConnection(peerConnection)
                    focusedPeerID = identity.id
                }
                recordConnectedDevice()
                resetReconnectAttempts()
                recordConnectionSuccess(for: identity.id)
            }
        case .connectionRequest:
            // Already handled during handshake
            break
        case .batchStart, .batchComplete:
            // Multi-file batch markers — handled by FileTransfer internally
            break

        case .ping:
            // Respond to keepalive ping with pong
            let pong = PeerMessage.pong(senderID: localIdentity.id)
            Task { [weak self] in
                do { try await self?.sendMessage(pong) }
                catch { logger.warning("Failed to send pong: \(error.localizedDescription)") }
            }

        case .pong:
            // Keepalive response received — connection is alive
            logger.debug("Heartbeat pong received from \(message.senderID)")

        case .messageReceipt:
            guard let payload = try? message.decodePayload(MessageReceiptPayload.self) else {
                logger.warning("Failed to decode MessageReceiptPayload")
                return
            }
            // Check if this is a group receipt
            if let groupID = payload.groupID, let senderID = payload.senderID {
                // Group message receipt - update per-member status
                for msgID in payload.messageIDs {
                    if payload.receiptType == .read {
                        chatManager.markGroupMessageRead(messageID: msgID, groupID: groupID, by: senderID)
                    } else {
                        chatManager.markGroupMessageDelivered(messageID: msgID, groupID: groupID, to: senderID)
                    }
                }
            } else {
                // 1-to-1 message receipt
                let newStatus: MessageStatus = payload.receiptType == .read ? .read : .delivered
                for msgID in payload.messageIDs {
                    chatManager.updateStatus(messageID: msgID, status: newStatus)
                }
            }

        case .typingIndicator:
            guard let payload = try? message.decodePayload(TypingIndicatorPayload.self) else {
                logger.warning("Failed to decode TypingIndicatorPayload")
                return
            }
            chatManager.setTyping(payload.isTyping, for: message.senderID)

        case .reaction:
            guard let payload = try? message.decodePayload(ReactionPayload.self) else {
                logger.warning("Failed to decode ReactionPayload")
                return
            }
            switch payload.action {
            case .add:
                chatManager.addReaction(emoji: payload.emoji, to: payload.messageID, from: message.senderID)
            case .remove:
                chatManager.removeReaction(emoji: payload.emoji, from: payload.messageID, by: message.senderID)
            }
        }
    }

    private func handleConnectionStateChange(_ nwState: NWConnection.State) {
        switch nwState {
        case .setup:
            logger.debug("Network connection initializing")
        case .waiting(let error):
            logger.info("Network connection waiting: \(error.localizedDescription)")
        case .preparing:
            logger.debug("Network connection preparing (TLS handshake in progress)")
        case .ready:
            logger.info("Network connection established and ready")
        case .failed(let error):
            cancelTimeouts()
            fileTransfer?.handleConnectionFailure()
            activeConnection = nil
            transition(to: .failed(reason: userFriendlyErrorMessage(error)))
            if discoveryCoordinator == nil {
                restartDiscovery()
            }
        case .cancelled:
            cancelTimeouts()
            activeConnection = nil
            // Transition out of active states so the app doesn't get stuck
            switch state {
            case .requesting, .connecting:
                transition(to: .failed(reason: "Connection was cancelled"))
                if discoveryCoordinator == nil { restartDiscovery() }
            case .connected, .transferring, .voiceCall:
                fileTransfer?.handleConnectionFailure()
                transition(to: .failed(reason: "Connection lost"))
                if discoveryCoordinator == nil { restartDiscovery() }
            default:
                break
            }
        @unknown default:
            logger.warning("Unknown network connection state")
        }
    }

    // MARK: - Message Receipts

    private func sendDeliveryReceipt(for messageID: String, to peerConnection: PeerConnection, groupID: String? = nil) {
        let payload = MessageReceiptPayload(
            messageIDs: [messageID],
            receiptType: .delivered,
            timestamp: Date(),
            groupID: groupID,
            senderID: groupID != nil ? localIdentity.id : nil
        )
        guard let msg = try? PeerMessage.messageReceipt(payload, senderID: localIdentity.id) else {
            logger.warning("Failed to create PeerMessage for messageReceipt")
            return
        }
        Task {
            do { try await peerConnection.sendMessage(msg) }
            catch { logger.warning("Failed to send delivery receipt: \(error.localizedDescription)") }
        }
    }

    func sendReadReceipts(for peerID: String) {
        guard let peerConn = connection(for: peerID) else { return }

        let unreadIDs = chatManager.getUnreadMessageIDs(for: peerID)
        guard !unreadIDs.isEmpty else { return }

        let payload = MessageReceiptPayload(
            messageIDs: unreadIDs,
            receiptType: .read,
            timestamp: Date()
        )
        guard let msg = try? PeerMessage.messageReceipt(payload, senderID: localIdentity.id) else {
            logger.warning("Failed to create PeerMessage for messageReceipt")
            return
        }
        Task {
            do { try await peerConn.sendMessage(msg) }
            catch { logger.warning("Failed to send read receipts: \(error.localizedDescription)") }
        }

        for msgID in unreadIDs {
            chatManager.updateStatus(messageID: msgID, status: .read)
        }
    }

    /// Send read receipts for group messages to all group members
    func sendGroupReadReceipts(for groupID: String, to members: [PeerIdentity]) {
        let unreadIDs = chatManager.getUnreadMessageIDs(for: groupID)
        guard !unreadIDs.isEmpty else { return }

        let payload = MessageReceiptPayload(
            messageIDs: unreadIDs,
            receiptType: .read,
            timestamp: Date(),
            groupID: groupID,
            senderID: localIdentity.id
        )
        guard let msg = try? PeerMessage.messageReceipt(payload, senderID: localIdentity.id) else {
            logger.warning("Failed to create PeerMessage for messageReceipt")
            return
        }

        // Send to all connected group members
        for member in members where member.id != localIdentity.id {
            if let peerConn = connection(for: member.id) {
                Task {
                    do { try await peerConn.sendMessage(msg) }
                    catch { logger.warning("Failed to send group read receipt to \(member.id): \(error.localizedDescription)") }
                }
            }
        }

        // Mark as read locally
        for msgID in unreadIDs {
            chatManager.updateStatus(messageID: msgID, status: .read)
        }
    }

    // MARK: - Typing Indicator

    func sendTypingIndicator(to peerID: String, isTyping: Bool) {
        guard let peerConn = connection(for: peerID) else { return }

        let payload = TypingIndicatorPayload(isTyping: isTyping, timestamp: Date())
        guard let msg = try? PeerMessage.typingIndicator(payload, senderID: localIdentity.id) else {
            logger.warning("Failed to create PeerMessage for typingIndicator")
            return
        }
        Task {
            do { try await peerConn.sendMessage(msg) }
            catch { logger.warning("Failed to send typing indicator: \(error.localizedDescription)") }
        }
    }

    func handleTypingChange(in peerID: String, hasText: Bool) {
        typingDebounceTask?.cancel()

        if hasText {
            if let last = lastTypingSent, Date().timeIntervalSince(last) < 2 { return }
            sendTypingIndicator(to: peerID, isTyping: true)
            lastTypingSent = Date()

            typingDebounceTask = Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await MainActor.run {
                    sendTypingIndicator(to: peerID, isTyping: false)
                }
            }
        } else {
            sendTypingIndicator(to: peerID, isTyping: false)
        }
    }

    // MARK: - Reactions

    func sendReaction(emoji: String, to messageID: String, action: ReactionPayload.Action, peerID: String) {
        guard let peerConn = connection(for: peerID) else { return }

        let payload = ReactionPayload(
            messageID: messageID,
            emoji: emoji,
            action: action,
            timestamp: Date()
        )
        guard let msg = try? PeerMessage.reaction(payload, senderID: localIdentity.id) else {
            logger.warning("Failed to create PeerMessage for reaction")
            return
        }

        Task {
            do { try await peerConn.sendMessage(msg) }
            catch { logger.warning("Failed to send reaction: \(error.localizedDescription)") }
        }

        // Update local state
        switch action {
        case .add:
            chatManager.addReaction(emoji: emoji, to: messageID, from: localIdentity.id)
        case .remove:
            chatManager.removeReaction(emoji: emoji, from: messageID, by: localIdentity.id)
        }
    }

    // MARK: - Chat

    func sendTextMessage(_ text: String, replyTo: ChatMessage? = nil) {
        guard FeatureSettings.isChatEnabled else { return }
        guard let peerID = focusedPeerID else { return }
        guard let peerConn = connections[peerID] else { return }
        let peer = peerConn.peerIdentity

        let payload = TextMessagePayload(
            text: text,
            replyToMessageID: replyTo?.id,
            replyToText: replyTo?.text ?? replyTo?.fileName,
            replyToSenderName: replyTo?.isOutgoing == true ? nil : (replyTo?.senderName ?? replyTo?.peerName)
        )
        guard let msg = try? PeerMessage.textMessage(payload, senderID: localIdentity.id) else {
            logger.warning("Failed to create PeerMessage for textMessage")
            return
        }
        let saved = chatManager.saveOutgoing(text: text, peerID: peer.id, peerName: peer.displayName, replyTo: replyTo)
        Task {
            do {
                try await peerConn.sendMessage(msg)
                await MainActor.run { chatManager.updateStatus(messageID: saved.id, status: .sent) }
            } catch {
                await MainActor.run { chatManager.updateStatus(messageID: saved.id, status: .failed) }
            }
        }
    }

    /// Send text message to a specific peer.
    func sendTextMessage(_ text: String, to peerID: String, replyTo: ChatMessage? = nil) {
        guard FeatureSettings.isChatEnabled else { return }
        guard let peerConn = connections[peerID] else { return }
        let peer = peerConn.peerIdentity

        let payload = TextMessagePayload(
            text: text,
            replyToMessageID: replyTo?.id,
            replyToText: replyTo?.text ?? replyTo?.fileName,
            replyToSenderName: replyTo?.isOutgoing == true ? nil : (replyTo?.senderName ?? replyTo?.peerName)
        )
        guard let msg = try? PeerMessage.textMessage(payload, senderID: localIdentity.id) else {
            logger.warning("Failed to create PeerMessage for textMessage")
            return
        }
        let saved = chatManager.saveOutgoing(text: text, peerID: peer.id, peerName: peer.displayName, replyTo: replyTo)
        Task {
            do {
                try await peerConn.sendMessage(msg)
                await MainActor.run { chatManager.updateStatus(messageID: saved.id, status: .sent) }
            } catch {
                await MainActor.run { chatManager.updateStatus(messageID: saved.id, status: .failed) }
            }
        }
    }

    func sendMediaMessage(mediaType: MediaMessagePayload.MediaType, fileName: String, fileData: Data, mimeType: String, duration: Double?, thumbnailData: Data?) {
        guard FeatureSettings.isChatEnabled else { return }
        guard let peerID = focusedPeerID else { return }
        guard let peerConn = connections[peerID] else { return }
        let peer = peerConn.peerIdentity

        let payload = MediaMessagePayload(mediaType: mediaType, fileName: fileName, fileSize: Int64(fileData.count), mimeType: mimeType, duration: duration, thumbnailData: thumbnailData)
        guard let msg = try? PeerMessage.mediaMessage(payload, senderID: localIdentity.id) else {
            logger.warning("Failed to create PeerMessage for mediaMessage")
            return
        }

        // Save locally
        let localPath: String?
        if !fileData.isEmpty {
            localPath = chatManager.saveMediaFile(data: fileData, fileName: fileName, peerID: peer.id)
        } else {
            localPath = nil
        }

        let saved = chatManager.saveOutgoingMedia(
            mediaType: mediaType,
            fileName: fileName,
            fileSize: Int64(fileData.count),
            mimeType: mimeType,
            duration: duration,
            localFileURL: localPath,
            thumbnailData: thumbnailData,
            peerID: peer.id,
            peerName: peer.displayName
        )

        // Send over network
        Task {
            do {
                try await peerConn.sendMessage(msg)
                await MainActor.run { chatManager.updateStatus(messageID: saved.id, status: .sent) }
            } catch {
                await MainActor.run { chatManager.updateStatus(messageID: saved.id, status: .failed) }
            }
        }
    }

    // MARK: - Group Connection

    /// Connect to all online devices in a group.
    func connectToGroup(_ group: DeviceGroup) {
        var connectedCount = 0
        var attemptedCount = 0

        for deviceID in group.deviceIDs {
            // Skip if already connected
            if isConnected(to: deviceID) {
                connectedCount += 1
                continue
            }

            // Check if we've reached max connections
            if activeConnectionCount >= maxConnections {
                break
            }

            // Try to find the peer in discovered peers
            if let peer = discoveredPeers.first(where: { $0.id == deviceID }) {
                requestConnection(to: peer)
                attemptedCount += 1
            } else if let record = deviceStore.records.first(where: { $0.id == deviceID }),
                      let host = record.host, let port = record.port {
                // Try to add as manual peer and connect
                addManualPeer(host: host, port: port, name: record.displayName)
                attemptedCount += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    if let peer = self?.discoveredPeers.first(where: { $0.id == deviceID }) {
                        self?.requestConnection(to: peer)
                    }
                }
            }
        }

        if attemptedCount == 0 && connectedCount < group.deviceIDs.count {
            statusToast = "No group members found nearby"
        }
    }

    /// Broadcast a text message to all connected members of a group.
    func broadcastTextMessage(_ text: String, toGroup groupID: String) {
        guard let group = groupStore.groups.first(where: { $0.id == groupID }) else { return }

        // Save the outgoing group message
        let saved = chatManager.saveGroupOutgoing(
            text: text,
            groupID: groupID,
            localName: localIdentity.displayName
        )

        // Include groupID and senderName in the payload
        let payload = TextMessagePayload(
            text: text,
            groupID: groupID,
            senderName: localIdentity.displayName
        )
        guard let msg = try? PeerMessage.textMessage(payload, senderID: localIdentity.id) else {
            logger.warning("Failed to create PeerMessage for textMessage")
            return
        }

        var sentCount = 0
        var failCount = 0

        for deviceID in group.deviceIDs {
            guard let peerConn = connections[deviceID], peerConn.state.isConnected else { continue }

            Task {
                do {
                    try await peerConn.sendMessage(msg)
                    sentCount += 1
                    // Update status when all sends complete
                    if sentCount + failCount == group.deviceIDs.count {
                        await MainActor.run {
                            chatManager.updateGroupMessageStatus(messageID: saved.id, status: .sent)
                        }
                    }
                } catch {
                    failCount += 1
                    if sentCount == 0 && failCount == group.deviceIDs.count {
                        await MainActor.run {
                            chatManager.updateGroupMessageStatus(messageID: saved.id, status: .failed)
                        }
                    }
                }
            }
        }

        // If no peers are connected, mark as failed immediately
        let connectedInGroup = group.deviceIDs.filter { isConnected(to: $0) }.count
        if connectedInGroup == 0 {
            chatManager.updateGroupMessageStatus(messageID: saved.id, status: .failed)
        }
    }

    /// Get connection status for group members.
    func groupConnectionStatus(_ group: DeviceGroup) -> (connected: Int, total: Int, online: Int) {
        let connectedCount = group.deviceIDs.filter { isConnected(to: $0) }.count
        let onlineCount = group.deviceIDs.filter { deviceID in
            discoveredPeers.contains { $0.id == deviceID }
        }.count
        return (connectedCount, group.deviceIDs.count, onlineCount)
    }

    // MARK: - Send helpers

    func sendMessage(_ message: PeerMessage) async throws {
        // Try focused peer connection first
        if let peerID = focusedPeerID, let peerConn = connections[peerID] {
            try await peerConn.sendMessage(message)
            return
        }

        // Fall back to legacy active connection
        guard let connection = activeConnection else {
            throw ConnectionError.notConnected
        }
        try await connection.sendMessage(message)
    }

    /// Send message to a specific peer.
    func sendMessage(_ message: PeerMessage, to peerID: String) async throws {
        guard let peerConn = connections[peerID] else {
            throw ConnectionError.notConnected
        }
        try await peerConn.sendMessage(message)
    }

    // MARK: - Transfer History Persistence

    private func loadTransferHistory() {
        guard let data = UserDefaults.standard.data(forKey: Self.transferHistoryKey) else { return }
        do {
            transferHistory = try JSONDecoder().decode([TransferRecord].self, from: data)
        } catch {
            logger.warning("Failed to decode transfer history: \(error.localizedDescription)")
        }
    }

    private func saveTransferHistory() {
        guard let data = try? JSONEncoder().encode(transferHistory) else {
            logger.warning("Failed to encode transfer history")
            return
        }
        UserDefaults.standard.set(data, forKey: Self.transferHistoryKey)
    }
}

enum ConnectionError: Error, LocalizedError {
    case notConnected
    case invalidState
    case maxConnectionsReached

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to a peer"
        case .invalidState: return "Invalid connection state"
        case .maxConnectionsReached: return "Maximum connections reached"
        }
    }
}

// MARK: - Retry Policy

/// Exponential backoff configuration for retry logic.
struct ExponentialBackoff {
    let initialDelay: TimeInterval
    let maxDelay: TimeInterval
    let multiplier: Double
    let maxAttempts: Int

    static let `default` = ExponentialBackoff(
        initialDelay: 1.0,
        maxDelay: 30.0,
        multiplier: 2.0,
        maxAttempts: 5
    )

    /// Calculate the delay for a given attempt number.
    func delay(for attempt: Int) -> TimeInterval {
        guard attempt < maxAttempts else { return maxDelay }
        let delay = initialDelay * pow(multiplier, Double(attempt))
        let jitter = Double.random(in: 0.9...1.1)
        return min(delay * jitter, maxDelay)
    }

    /// Check if another retry attempt is allowed.
    func canRetry(_ attempt: Int) -> Bool {
        attempt < maxAttempts
    }
}

/// Actor that controls retry timing with exponential backoff.
actor RetryController {
    private let policy: ExponentialBackoff
    private(set) var attemptCount = 0

    init(policy: ExponentialBackoff = .default) {
        self.policy = policy
    }

    /// Get the delay for the next retry attempt.
    func nextDelay() -> TimeInterval? {
        guard policy.canRetry(attemptCount) else { return nil }
        let delay = policy.delay(for: attemptCount)
        attemptCount += 1
        return delay
    }

    /// Reset the attempt counter (call on successful connection).
    func reset() {
        attemptCount = 0
    }

    /// Get the current attempt count without incrementing.
    var currentAttempt: Int {
        attemptCount
    }
}
