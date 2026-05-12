import Foundation
import Network
import Combine
import CryptoKit
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

/// Pending PIN verification for a relay connection.
struct RelayPINRequest: Identifiable {
    let id = UUID()
    let pin: String
    let peerID: String
    let remoteFingerprint: String
}

/// Info for displaying a key change alert
struct KeyChangeAlertInfo: Identifiable {
    let id = UUID()
    let contactName: String
    let contactId: UUID
    let oldFingerprint: String
    let newFingerprint: String
    let newPublicKey: Data
}

/// Surfaced to the user after a configurable number of consecutive decrypt
/// failures from the same peer. Drives a dismissible banner in `ChatView`
/// suggesting the user verify the peer's fingerprint (e.g., the peer rotated
/// their identity key without our knowledge, or a session is corrupted).
struct DecryptFailureBanner: Identifiable, Equatable {
    let contactId: String
    let displayName: String
    var id: String { contactId }
}

/// An envelope from an unknown peer awaiting user consent before X3DH session
/// establishment. The fingerprint is the short human-readable hex string the
/// user compares out-of-band to defend against MITM at first contact.
struct PendingFirstContact: Equatable, Identifiable {
    let fingerprint: String           // stable dedup key (also used as Identifiable id)
    let senderDisplayName: String     // what to show in the sheet
    let senderIdentityKey: Data
    /// Short Authentication String (6 digits, "NNN NNN") derived from the
    /// canonically-ordered identity key pair. Present when the prompt is
    /// driven by a `LocalSecureChannel` handshake (local-Wi-Fi audit-#14
    /// Stage 2). Nil for remote-mailbox first-contacts, which surface the
    /// SHA-256 hex fingerprint only.
    let sas: String?

    init(
        fingerprint: String,
        senderDisplayName: String,
        senderIdentityKey: Data,
        sas: String? = nil
    ) {
        self.fingerprint = fingerprint
        self.senderDisplayName = senderDisplayName
        self.senderIdentityKey = senderIdentityKey
        self.sas = sas
    }

    var id: String { fingerprint }
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
    /// Pending PIN verification for relay connections (nil = no verification needed).
    @Published var pendingRelayPIN: RelayPINRequest?
    /// Relay room code received via deep link, triggers RelayConnectView auto-join.
    @Published var pendingRelayJoinCode: String?
    /// Set when a BLE-only peer is tapped; triggers RelayConnectView to open.
    @Published var shouldShowRelayConnect = false
    /// Device ID currently being invited via `inviteKnownDevice` (for UI loading state).
    @Published var invitingDeviceId: String?
    /// Surface invite errors to the UI (transient; auto-cleared on next success or 5s).
    @Published var inviteError: String?
    /// Pending key change alert for a contact whose key has changed
    @Published var pendingKeyChangeAlert: KeyChangeAlertInfo?
    /// Pending first-contact verification: an envelope from an unknown peer
    /// awaiting user consent before we create a TrustedContact and respond
    /// to X3DH. Drives the FirstContactVerificationSheet.
    @Published var pendingFirstContact: PendingFirstContact?
    /// Pending local-Wi-Fi first-trust verification: a peer we just completed
    /// a `LocalSecureChannel` handshake with whose identity key is unknown
    /// to `TrustedContactStore`. Closes the audit-#14 TOFU gap by surfacing
    /// the fingerprint to the user instead of silently auto-trusting.
    /// Drives a second mount of `FirstContactVerificationSheet`.
    @Published var pendingLocalFirstTrust: PendingFirstContact?

    /// Surfaced banner when consecutive decrypt failures from a single peer
    /// cross `decryptFailureBannerThreshold`. Cleared on successful decrypt
    /// from the same peer or explicit user dismissal.
    @Published var decryptFailureBanner: DecryptFailureBanner?

    /// Per-contact running count of consecutive decrypt failures. Reset to 0
    /// on a successful decrypt from the same peer. Keyed by `contact.id.uuidString`.
    private var consecutiveDecryptFailures: [String: Int] = [:]

    /// Number of back-to-back decrypt failures from the same peer required
    /// before we surface a banner to the user. Picked to ride out brief
    /// out-of-order ratchet hiccups without nagging.
    private static let decryptFailureBannerThreshold = 3

    /// Envelopes awaiting user consent. Insertion-ordered so that when the
    /// active `pendingFirstContact` is resolved (approve or reject), the next
    /// queued unknown peer can be surfaced to the user. Each entry holds the
    /// fingerprint dedup key (base64 of identity key), the parsed envelope,
    /// and the original wire message so we can replay once approved.
    private var pendingFirstContactEnvelopes: [(fpKey: String, envelope: RemoteMessageEnvelope, message: MailboxMessage)] = []

    /// Maximum number of unknown peers we will queue for first-contact
    /// consent. Guards against a hostile peer (or botnet) from filling the
    /// queue unboundedly until the user notices. Once at capacity, additional
    /// envelopes from new peers are dropped.
    private static let maxPendingFirstContacts = 16

    let tailnetStore = TailnetPeerStore()

    var onPeerConnectedForPet: ((String) -> Void)?
    var onPeerDisconnectedForPet: ((String) -> Void)?

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
    private var bleDiscovery: BLEDiscovery?
    private(set) var nearbyInteractionManager: NearbyInteractionManager?
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
    let clipboardSyncManager = ClipboardSyncManager()
    let trustedContactStore = TrustedContactStore()

    // MARK: - Remote Communication (Phase 2)

    let preKeyStore = PreKeyStore()
    private(set) lazy var mailboxManager = MailboxManager(preKeyStore: preKeyStore)
    private(set) lazy var remoteSessionManager = RemoteSessionManager(preKeyStore: preKeyStore)

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

        // Wire clipboard sync: start monitoring and broadcast changes to all connected peers
        clipboardSyncManager.onClipboardChanged = { [weak self] payload in
            self?.sendClipboardSyncToAll(payload)
        }
        clipboardSyncManager.startMonitoring()

        // Wire remote mailbox message handler
        mailboxManager.onMessageReceived = { [weak self] message in
            self?.handleRemoteMessage(message)
        }

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
        onPeerConnectedForPet?(peerID)
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
        onPeerDisconnectedForPet?(peerID)
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
            case .bluetooth: sourceType = "bluetooth"
            case .relay: sourceType = "relay"
            }
            switch lastPeer.endpoint {
            case .manual(let h, let p):
                host = h; port = p
            case .bonjour, .bleOnly, .relay:
                host = nil; port = nil
            }
        } else {
            sourceType = "bonjour"; host = nil; port = nil
        }
        let id = lastConnectedPeer?.id ?? peer.id
        deviceStore.addOrUpdate(id: id, displayName: peer.displayName, sourceType: sourceType, host: host, port: port)
    }

    // MARK: - Nearby Interaction

    private func startNearbyInteractionSession(for peerID: String, via peerConnection: PeerConnection) {
        guard let niManager = nearbyInteractionManager else { return }
        niManager.startSession(for: peerID) { [weak self] tokenData in
            guard let self else { return }
            let offer = PeerMessage(type: .niTokenOffer, payload: tokenData, senderID: self.localIdentity.id)
            Task {
                do { try await peerConnection.sendMessage(offer) }
                catch { logger.warning("Failed to send NI token offer: \(error.localizedDescription)") }
            }
        }
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

        // Auto-report connection failures for remote debugging
        if case .failed(let reason) = newState {
            ErrorReporter.report(
                error: reason,
                context: "ConnectionManager.transition",
                extras: [
                    "fromState": String(describing: oldState),
                    "focusedPeer": focusedPeerID ?? "none",
                    "connectionCount": "\(connections.count)",
                ]
            )
        }

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

    /// Force the state machine to `.requesting` from any state, using valid transition paths.
    /// Used by relay functions that need to start from a clean `.requesting` state.
    private func forceTransitionToRequesting() {
        switch state {
        case .requesting:
            return // Already there
        case .discovering:
            transition(to: .peerFound)
            transition(to: .requesting)
        case .peerFound:
            transition(to: .requesting)
        case .idle:
            transition(to: .discovering)
            transition(to: .peerFound)
            transition(to: .requesting)
        case .disconnected, .failed, .rejected:
            transition(to: .discovering)
            transition(to: .peerFound)
            transition(to: .requesting)
        case .connected, .transferring, .voiceCall:
            // Already connected — force through disconnected path
            transition(to: .disconnected)
            transition(to: .discovering)
            transition(to: .peerFound)
            transition(to: .requesting)
        case .connecting:
            transition(to: .failed(reason: ""))
            transition(to: .discovering)
            transition(to: .peerFound)
            transition(to: .requesting)
        case .incomingRequest:
            transition(to: .discovering)
            transition(to: .peerFound)
            transition(to: .requesting)
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

        var backends: [DiscoveryBackend] = [bonjour]

        // Add BLE discovery if enabled
        if FeatureSettings.isBLEDiscoveryEnabled {
            let ble = BLEDiscovery(localPeerID: localIdentity.id, localDisplayName: localIdentity.displayName)
            backends.append(ble)
            self.bleDiscovery = ble
        }

        let coordinator = DiscoveryCoordinator(backends: backends)
        coordinator.$peers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] coordinatorPeers in
                guard let self else { return }
                self.updateDiscoveredPeers(coordinatorPeers: coordinatorPeers)
            }
            .store(in: &cancellables)

        // Also observe tailnet store changes
        tailnetStore.$entries
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateDiscoveredPeers(coordinatorPeers: self.discoveryCoordinator?.peers ?? [])
            }
            .store(in: &cancellables)

        coordinator.start()
        self.bonjourDiscovery = bonjour
        self.discoveryCoordinator = coordinator

        // Start Nearby Interaction if enabled
        if FeatureSettings.isNearbyInteractionEnabled {
            self.nearbyInteractionManager = NearbyInteractionManager()
        }
        transition(to: .discovering)

        // Start network path monitoring
        startNetworkPathMonitor()
    }

    private func updateDiscoveredPeers(coordinatorPeers: [DiscoveredPeer]) {
        var peers = coordinatorPeers
        for entry in tailnetStore.entries where tailnetStore.isReachable(entry.id) {
            let id = "tailnet:\(entry.id.uuidString)"
            // Don't duplicate if coordinator already has this peer
            guard !peers.contains(where: { $0.id == id }) else { continue }
            let peer = DiscoveredPeer(
                id: id,
                displayName: entry.displayName,
                endpoint: .manual(host: entry.ip, port: entry.port),
                source: .manual
            )
            peers.append(peer)
        }
        discoveredPeers = peers
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
        bleDiscovery = nil
        nearbyInteractionManager?.stopAllSessions()
        nearbyInteractionManager = nil
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

    /// The port this device's Bonjour listener is running on (for QR code / deep link).
    var localListenerPort: UInt16? {
        bonjourDiscovery?.actualPort
    }

    func addManualPeer(host: String, port: UInt16, name: String?) {
        discoveryCoordinator?.addManualPeer(host: host, port: port, name: name)
    }

    func removeManualPeer(id: String) {
        discoveryCoordinator?.removeManualPeer(id: id)
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

        // Auto-remove manual peers after 5 consecutive failures
        if failure.count >= 5,
           let peer = discoveredPeers.first(where: { $0.id == peerID }),
           peer.source == .manual {
            logger.info("Removing manual peer \(peerID.prefix(8)) after \(failure.count) consecutive failures")
            removeManualPeer(id: peerID)
            failedPeers.removeValue(forKey: peerID)
        }
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

    // MARK: - Remote Message Handling

    private func handleRemoteMessage(_ message: MailboxMessage) {
        guard let ciphertextData = Data(base64Encoded: message.ciphertext) else {
            logger.error("Remote message has invalid base64 ciphertext")
            return
        }

        do {
            let envelope = try JSONDecoder().decode(RemoteMessageEnvelope.self, from: ciphertextData)

            // Find contact by public key, or by mailbox ID
            let contact = trustedContactStore.find(byPublicKey: envelope.senderIdentityKey)
                ?? trustedContactStore.find(byMailboxId: envelope.senderMailboxId)

            if let c = contact, c.isBlocked {
                logger.debug("Remote message from blocked contact — discarding")
                return
            }

            // First message from unknown sender: GATE on user consent.
            // Do NOT auto-create the contact or call respondToSession — instead,
            // queue the envelope and surface the fingerprint so the user can
            // verify the peer out-of-band (see FirstContactVerificationSheet).
            if contact == nil && envelope.isInitialMessage {
                let fpKey = envelope.senderIdentityKey.base64EncodedString()
                if pendingFirstContactEnvelopes.contains(where: { $0.fpKey == fpKey }) {
                    // Duplicate envelope from same unknown peer — dedup.
                    logger.debug("Duplicate first-contact envelope from same unknown peer — already queued")
                    return
                }
                guard pendingFirstContactEnvelopes.count < Self.maxPendingFirstContacts else {
                    logger.warning("First-contact queue at capacity (\(Self.maxPendingFirstContacts)); dropping envelope from new peer")
                    return
                }
                pendingFirstContactEnvelopes.append((fpKey: fpKey, envelope: envelope, message: message))
                if pendingFirstContact == nil {
                    let displayFingerprint = Self.computeFingerprint(of: envelope.senderIdentityKey)
                    pendingFirstContact = PendingFirstContact(
                        fingerprint: displayFingerprint,
                        senderDisplayName: envelope.senderDisplayName ?? String(localized: "Remote Peer"),
                        senderIdentityKey: envelope.senderIdentityKey
                    )
                    logger.info("First contact from unknown peer pending user consent")
                } else {
                    logger.info("Additional unknown peer queued behind active first-contact; will surface after current decision")
                }
                return // wait for user approval
            }

            guard let contact else {
                logger.warning("Remote message from unknown sender with no X3DH — discarding")
                return
            }

            // Ensure mailboxId is set on contact
            if contact.mailboxId == nil {
                trustedContactStore.updateMailboxId(for: contact.id, mailboxId: envelope.senderMailboxId)
            }

            // Establish session if needed (responder side)
            if !remoteSessionManager.hasSession(for: contact.id.uuidString),
               let ephKey = envelope.ephemeralKey,
               let spkId = envelope.usedSignedPreKeyId {
                _ = try remoteSessionManager.respondToSession(
                    contactId: contact.id.uuidString,
                    theirIdentityKey: envelope.senderIdentityKey,
                    theirEphemeralKey: ephKey,
                    usedSignedPreKeyId: spkId,
                    usedOneTimePreKeyId: envelope.usedOneTimePreKeyId
                )
            }

            // Decrypt is wrapped in its own do/catch so we can track consecutive
            // failures per peer and surface a banner to the user. Other errors
            // (envelope decode, session establishment) flow through the OUTER
            // catch unchanged.
            let plaintext: Data
            do {
                plaintext = try remoteSessionManager.decrypt(
                    message: envelope.ratchetMessage,
                    from: contact.id.uuidString
                )
                // Successful decrypt — reset the failure counter for this peer.
                consecutiveDecryptFailures[contact.id.uuidString] = 0
                // If a banner was visible for this peer, dismiss it (recovered).
                if decryptFailureBanner?.contactId == contact.id.uuidString {
                    decryptFailureBanner = nil
                }
            } catch {
                let count = (consecutiveDecryptFailures[contact.id.uuidString] ?? 0) + 1
                consecutiveDecryptFailures[contact.id.uuidString] = count
                logger.error("Decrypt failure #\(count) from \(contact.displayName): \(error.localizedDescription)")
                if count >= Self.decryptFailureBannerThreshold,
                   decryptFailureBanner?.contactId != contact.id.uuidString {
                    decryptFailureBanner = DecryptFailureBanner(
                        contactId: contact.id.uuidString,
                        displayName: contact.displayName
                    )
                }
                return
            }

            if let text = String(data: plaintext, encoding: .utf8) {
                chatManager.saveIncoming(
                    text: text,
                    peerID: contact.id.uuidString,
                    peerName: contact.displayName
                )
            }
        } catch {
            logger.error("Failed to process remote message: \(error.localizedDescription)")
        }
    }

    /// User-initiated dismissal of the decrypt-failure banner. Resets the
    /// per-peer failure counter so the banner does not immediately re-appear
    /// on the next failure — it will only return after `threshold` NEW
    /// consecutive failures from the same peer.
    func dismissDecryptFailureBanner() {
        if let banner = decryptFailureBanner {
            consecutiveDecryptFailures[banner.contactId] = 0
        }
        decryptFailureBanner = nil
    }

    #if DEBUG
    /// Test-only: simulate a decrypt failure from a peer without driving the
    /// full `handleRemoteMessage` flow. Mirrors the production branch.
    func recordDecryptFailureForTesting(contactId: String, displayName: String) {
        let count = (consecutiveDecryptFailures[contactId] ?? 0) + 1
        consecutiveDecryptFailures[contactId] = count
        if count >= Self.decryptFailureBannerThreshold,
           decryptFailureBanner?.contactId != contactId {
            decryptFailureBanner = DecryptFailureBanner(
                contactId: contactId, displayName: displayName)
        }
    }

    /// Test-only: simulate a successful decrypt from a peer.
    func recordDecryptSuccessForTesting(contactId: String) {
        consecutiveDecryptFailures[contactId] = 0
        if decryptFailureBanner?.contactId == contactId {
            decryptFailureBanner = nil
        }
    }
    #endif

    // MARK: - First-Contact Verification

    /// Compute the human-readable fingerprint shown to the user for a sender's
    /// identity key. Mirrors `TrustedContact.keyFingerprint` so the on-screen
    /// value matches what users see for already-trusted contacts.
    static func computeFingerprint(of publicKey: Data) -> String {
        let hash = SHA256.hash(data: publicKey)
        let hex = hash.prefix(10).map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: 20, by: 4).map { i in
            let start = hex.index(hex.startIndex, offsetBy: i)
            let end = hex.index(start, offsetBy: 4)
            return String(hex[start..<end])
        }.joined(separator: " ")
    }

    /// User approved a first-contact. Replay the queued envelope through the
    /// normal flow: create contact at `.linked` trust, then re-enter
    /// `handleRemoteMessage` so the existing X3DH respond + decrypt path runs.
    func approveFirstContact(fingerprint: String) {
        guard let current = pendingFirstContact, current.fingerprint == fingerprint else { return }
        let fpKey = current.senderIdentityKey.base64EncodedString()
        guard let idx = pendingFirstContactEnvelopes.firstIndex(where: { $0.fpKey == fpKey }) else { return }
        let pending = pendingFirstContactEnvelopes.remove(at: idx)
        pendingFirstContact = nil

        let newContact = TrustedContact(
            displayName: current.senderDisplayName,
            identityPublicKey: current.senderIdentityKey,
            trustLevel: .linked,
            mailboxId: pending.envelope.senderMailboxId
        )
        trustedContactStore.add(newContact)
        logger.info("Created first-contact after user approval: \(newContact.displayName)")
        // Re-enter handleRemoteMessage now that the contact exists — the
        // unknown-peer branch will be skipped and the normal X3DH responder +
        // decrypt + deliver path runs.
        handleRemoteMessage(pending.message)
        // Surface the next queued unknown peer (if any) so the user can act
        // on them. Multi-peer UX: don't silently strand peers behind the one
        // that just resolved.
        surfaceNextPendingFirstContact()
    }

    /// User rejected a first-contact. Discard the queued envelope and do not
    /// create a TrustedContact; the X3DH session is never established.
    func rejectFirstContact(fingerprint: String) {
        guard let current = pendingFirstContact, current.fingerprint == fingerprint else { return }
        let fpKey = current.senderIdentityKey.base64EncodedString()
        pendingFirstContactEnvelopes.removeAll(where: { $0.fpKey == fpKey })
        pendingFirstContact = nil
        logger.info("User rejected first-contact from unknown peer")
        // Surface the next queued unknown peer (if any).
        surfaceNextPendingFirstContact()
    }

    /// After the active `pendingFirstContact` is resolved, promote the next
    /// queued envelope (in insertion order) into the published slot so the
    /// FirstContactVerificationSheet can show it. No-op if a pending contact
    /// is still set or the queue is empty.
    private func surfaceNextPendingFirstContact() {
        guard pendingFirstContact == nil else { return }
        guard let next = pendingFirstContactEnvelopes.first else { return }
        pendingFirstContact = PendingFirstContact(
            fingerprint: Self.computeFingerprint(of: next.envelope.senderIdentityKey),
            senderDisplayName: next.envelope.senderDisplayName ?? String(localized: "Remote Peer"),
            senderIdentityKey: next.envelope.senderIdentityKey
        )
    }

    #if DEBUG
    /// Test-only: invoke the private `handleRemoteMessage` so unit tests can
    /// drive the consent gate without going through MailboxManager.
    func handleRemoteMessageForTesting(_ message: MailboxMessage) {
        handleRemoteMessage(message)
    }
    #endif

    func sendRemoteMessage(text: String, to contact: TrustedContact) async throws {
        guard let peerMailboxId = contact.mailboxId else {
            throw MailboxError.httpError(0) // Contact has no mailbox — cannot send
        }

        // Ensure our own mailbox is registered so the recipient can reply
        try await mailboxManager.registerIfNeeded()
        guard let myMailboxId = mailboxManager.mailboxId else {
            throw RemoteInviteError.mailboxNotRegistered
        }

        guard let plaintext = text.data(using: .utf8) else { return }
        let encrypted = try remoteSessionManager.encrypt(data: plaintext, for: contact.id.uuidString)

        let envelope = RemoteMessageEnvelope(
            senderIdentityKey: IdentityKeyManager.shared.publicKey.rawRepresentation,
            senderMailboxId: myMailboxId,
            senderDisplayName: nil,
            ephemeralKey: nil,
            usedSignedPreKeyId: nil,
            usedOneTimePreKeyId: nil,
            ratchetMessage: encrypted
        )

        let envelopeData = try JSONEncoder().encode(envelope)
        let challenge = UUID().uuidString
        guard let pow = ProofOfWork.generate(challenge: challenge) else {
            throw MailboxError.invalidResponse
        }

        try await MailboxClient().sendMessage(
            to: peerMailboxId,
            ciphertext: envelopeData,
            pow: ProofOfWorkToken(challenge: challenge, proof: pow)
        )

        // Save as outgoing message in chat history
        chatManager.saveOutgoing(
            text: text,
            peerID: contact.id.uuidString,
            peerName: contact.displayName
        )
    }

    // MARK: - Accept Remote Invite

    func acceptRemoteInvite(_ invite: InvitePayload) async throws {
        // 1. Dedup — if already accepted this invite, skip
        if let existing = trustedContactStore.find(byMailboxId: invite.mailboxId) {
            logger.info("Invite already accepted for mailbox \(invite.mailboxId), contact: \(existing.displayName)")
            return
        }

        // 2. Ensure our mailbox is registered
        try await mailboxManager.registerIfNeeded()
        guard let myMailboxId = mailboxManager.mailboxId else {
            throw RemoteInviteError.mailboxNotRegistered
        }

        // 3. Fetch peer's pre-key bundle
        let bundle = try await MailboxClient().fetchPreKeyBundle(mailboxId: invite.mailboxId)

        // 4. TOFU: verify fetched identity key matches the fingerprint from the invite
        let fetchedContact = TrustedContact(
            displayName: invite.displayName,
            identityPublicKey: bundle.identityKey,
            trustLevel: .linked,
            mailboxId: invite.mailboxId
        )
        guard fetchedContact.keyFingerprint == invite.identityKeyFingerprint else {
            logger.error("TOFU verification failed: invite fingerprint \(invite.identityKeyFingerprint) != bundle fingerprint \(fetchedContact.keyFingerprint)")
            throw RemoteInviteError.fingerprintMismatch
        }

        // 5. Add trusted contact
        trustedContactStore.add(fetchedContact)

        // 6. Initiate X3DH session
        let result = try await remoteSessionManager.initiateSession(
            contactId: fetchedContact.id.uuidString,
            peerMailboxId: invite.mailboxId
        )

        // 7. Send initial encrypted greeting
        let greeting = String(localized: "Connected via invite link").data(using: .utf8)!
        let encrypted = try remoteSessionManager.encrypt(data: greeting, for: fetchedContact.id.uuidString)

        let envelope = RemoteMessageEnvelope(
            senderIdentityKey: IdentityKeyManager.shared.publicKey.rawRepresentation,
            senderMailboxId: myMailboxId,
            senderDisplayName: PeerIdentity.local().displayName,
            ephemeralKey: result.ephemeralPublicKey,
            usedSignedPreKeyId: result.usedSignedPreKeyId,
            usedOneTimePreKeyId: result.usedOneTimePreKeyId,
            ratchetMessage: encrypted
        )

        let envelopeData = try JSONEncoder().encode(envelope)
        let challenge = UUID().uuidString
        guard let pow = ProofOfWork.generate(challenge: challenge) else {
            throw MailboxError.invalidResponse
        }

        try await MailboxClient().sendMessage(
            to: invite.mailboxId,
            ciphertext: envelopeData,
            pow: ProofOfWorkToken(challenge: challenge, proof: pow)
        )
    }

    enum RemoteInviteError: LocalizedError {
        case fingerprintMismatch
        case mailboxNotRegistered

        var errorDescription: String? {
            switch self {
            case .fingerprintMismatch:
                return String(localized: "Security verification failed: the peer's identity key does not match the invite. The connection may have been tampered with.")
            case .mailboxNotRegistered:
                return String(localized: "Could not register mailbox. Please try again.")
            }
        }
    }

    // MARK: - App Lifecycle

    func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .active:
            endBackgroundTask()
            discoveryCoordinator?.cleanupStalePeers(olderThan: 86400)
            mailboxManager.startPolling()
            Task { await mailboxManager.uploadPreKeysIfNeeded() }
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
            trustedContactStore.flushPendingSave()
            preKeyStore.flush()
            mailboxManager.stopPolling()
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
                // Stop Bonjour to save power, but keep BLE advertising
                // so this device remains discoverable in background
                bonjourDiscovery?.stopDiscovery()
                bonjourDiscovery = nil
                discoveryCoordinator?.stop()
                discoveryCoordinator = nil
                nearbyInteractionManager?.stopAllSessions()
                nearbyInteractionManager = nil
                stopNetworkPathMonitor()
                // BLE kept alive via bluetooth-peripheral background mode
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
        logger.warning("Background task expiring")

        // Only disconnect relay (WebRTC) connections; keep local TCP connections alive
        Task {
            for (peerID, peerConn) in connections {
                if peerConn.transport is DataChannelTransport {
                    logger.info("Closing relay connection for \(peerID.prefix(8)) on background expiry")
                    await peerConn.disconnect()
                    await MainActor.run { removeConnection(peerID: peerID) }
                }
                // Local TCP connections: preserved via iOS socket keepalive
            }
        }

        // Legacy active connection: preserve (TCP), iOS maintains socket
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
                try await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
                guard let self, !Task.isCancelled, self.connectionGeneration == gen else { return }
                if case .requesting = self.state {
                    logger.warning("Connection request timed out after 10s")
                    if let conn = self.activeConnection {
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
                    if let conn = self.activeConnection {
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

        // Early return for endpoints that don't use NWConnection — no state transition needed
        switch peer.endpoint {
        case .bleOnly:
            if FeatureSettings.isRelayEnabled {
                logger.info("BLE-only peer tapped with relay enabled, opening Relay Connect: \(peer.displayName)")
                shouldShowRelayConnect = true
            } else {
                logger.info("BLE-only peer tapped: \(peer.displayName), showing WiFi required toast")
                statusToast = String(localized: "Connect to the same WiFi network to transfer files")
            }
            return
        case .relay:
            logger.info("Relay peer connection not handled here")
            return
        default:
            break
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
        case .bleOnly, .relay:
            return // Already handled above
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
                // Restore stateUpdateHandler (waitReady replaces it internally)
                connection.stateUpdateHandler = { [weak self] nwState in
                    logger.info("NWConnection state: \(String(describing: nwState))")
                    Task { @MainActor in
                        guard let self, self.connectionGeneration == generation else { return }
                        self.handleConnectionStateChange(nwState)
                    }
                }
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
                checkPeerTrust(peerIdentity: peerIdentity)

                // Auto-add incoming tailnet peers
                if let remoteHost = self.extractRemoteHost(from: connection.endpoint),
                   self.isTailnetIP(remoteHost) {
                    self.tailnetStore.addIfMissing(displayName: peerIdentity.displayName, ip: remoteHost)
                }

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

                // Start Nearby Interaction session if available
                self.startNearbyInteractionSession(for: peerID, via: peerConnection)

                // v5.1: peer's hello arrived inline above; capability flag
                // is known. Kick off LocalSecureChannel handshake.
                triggerSecureChannelNegotiation(for: peerConnection)
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

    // MARK: - Relay Connection (Worker Signaling)

    /// Active relay session timer.
    private var relaySessionTimer: Task<Void, Never>?
    /// Holds the PeerConnection waiting for PIN verification before handshake.
    private var pendingRelayPeerConnection: PeerConnection?
    /// Active BLE signaling instance.
    private(set) var bleSignaling: BLESignaling?
    /// In-progress invite accepts — prevents dual WS+APNs delivery from spawning parallel negotiations.
    private var inProgressInviteRoomCodes: [String: Date] = [:]
    private let inviteDedupTTL: TimeInterval = 60

    /// Currently in-flight relay session. Held so its `deinit` does not
    /// fire until ConnectionManager replaces it (e.g. supersession via
    /// generation change) or the session reaches `.connected`.
    /// CRITICAL: `RelaySession.deinit` closes signaling if the outcome is
    /// not `.connected` — that is the structural v3.3.0 zombie-socket fix.
    private var activeRelaySession: RelaySession?

    /// Reference-typed flag holder used by `startWorkerRelayAsCreator` to
    /// capture a `peer-joined` event that arrives during the ICE-credentials
    /// HTTPS round-trip. A class lets the WS callback closure mutate the flag
    /// without needing inout semantics.
    private final class PeerJoinedBox {
        var fired: Bool = false
    }

    /// Start a relay connection as the room creator (offerer).
    func startWorkerRelayAsCreator(roomCode: String, roomToken: String? = nil, signaling: WorkerSignaling) {
        logger.info("Starting relay as creator for room: \(roomCode)")

        let generation = UUID()
        connectionGeneration = generation
        forceTransitionToRequesting()

        // CRITICAL race fix: install a one-shot buffering shim on
        // `onPeerJoined` BEFORE calling `joinRoom`. The WS receive loop may
        // deliver `peer-joined` while we are still awaiting the ICE-credentials
        // HTTPS round-trip, and `RelaySession.startCreator` only installs its
        // real handler at the end of that round-trip. Without this shim the
        // event would be dropped (callback was nil) and the offer would never
        // be sent → 30s negotiation timeout.
        //
        // `RelaySession.startCreator` REPLACES this shim with its real handler;
        // if the shim already saw the event we forward `peerAlreadyJoined: true`
        // so the session sends the offer immediately.
        let peerJoinedBox = PeerJoinedBox()
        signaling.onPeerJoined = { peerJoinedBox.fired = true }

        // Open the WebSocket — we already have the token from createRoom.
        signaling.joinRoom(code: roomCode, token: roomToken)

        // Cancel any in-flight session before installing the new one. cancel()
        // is idempotent and ensures the previous attempt's signaling closes
        // even if its deinit hasn't fired yet.
        activeRelaySession?.cancel(reason: "supersededByCreator")
        activeRelaySession = nil

        Task { [weak self] in
            guard let self else { return }
            let metricsToken = await ConnectionMetrics.shared.begin(
                type: .relayWorker, role: .initiator
            )
            // Best-effort ICE/TURN credentials; nil → STUN-only fallback.
            let iceResult = try? await signaling.requestICECredentials(roomCode: roomCode)

            await MainActor.run {
                guard self.connectionGeneration == generation else { return }

                let session = RelaySession(
                    roomCode: roomCode,
                    role: .creator,
                    signaling: signaling,
                    metricsToken: metricsToken,
                    iceResult: iceResult,
                    logger: logger
                )
                session.onConnected = { [weak self] transport in
                    guard let self, self.connectionGeneration == generation else { return }
                    self.completeRelayConnection(transport: transport, roomCode: roomCode)
                }
                session.onFailed = { [weak self] reason in
                    guard let self, self.connectionGeneration == generation else { return }
                    self.transition(to: .failed(reason: reason))
                }
                self.activeRelaySession = session
                let alreadyJoined = peerJoinedBox.fired
                Task { @MainActor in
                    await session.start(peerAlreadyJoined: alreadyJoined)
                }
            }
        }
    }

    /// Start a relay connection as a joiner (answerer).
    func startWorkerRelayAsJoiner(roomCode: String, signaling: WorkerSignaling) async throws {
        logger.info("Starting relay as joiner for room: \(roomCode)")

        let generation = UUID()
        connectionGeneration = generation
        forceTransitionToRequesting()

        let metricsToken = await ConnectionMetrics.shared.begin(
            type: .relayWorker, role: .joiner
        )

        // Get ICE/TURN credentials + room token (fallback to STUN if TURN unavailable).
        var iceResult: WorkerSignaling.ICEResult?
        var iceError: Error?
        do {
            iceResult = try await signaling.requestICECredentials(roomCode: roomCode)
            logger.info("ICE credentials received for room \(roomCode), token: \(iceResult?.roomToken != nil ? "present" : "nil")")
        } catch {
            iceError = error
            let nsError = error as NSError
            logger.error("ICE credentials request failed for room \(roomCode): domain=\(nsError.domain) code=\(nsError.code) \(nsError.localizedDescription)")
            ErrorReporter.report(
                error: nsError.localizedDescription,
                context: "relay.joiner.iceRequest",
                extras: [
                    "roomCode": roomCode,
                    "errorDomain": nsError.domain,
                    "errorCode": "\(nsError.code)",
                    "step": "requestICECredentials",
                ]
            )
        }

        // If ICE request failed, we have no room token — WebSocket auth will fail.
        guard iceResult?.roomToken != nil else {
            let detail = iceError?.localizedDescription ?? "No room token received"
            logger.error("No room token for room \(roomCode): \(detail)")
            await ConnectionMetrics.shared.recordFailure(
                metricsToken,
                reason: "iceRequest: \(detail)"
            )
            transition(to: .failed(reason: "Relay failed: \(detail) (room: \(roomCode))"))
            return
        }

        signaling.joinRoom(code: roomCode, token: iceResult?.roomToken)
        await launchJoinerSession(
            roomCode: roomCode,
            signaling: signaling,
            iceResult: iceResult,
            generation: generation,
            metricsToken: metricsToken
        )
    }

    /// Joiner flow for invite-driven connections — uses the roomToken from the invite
    /// instead of racing ICE→token fetch. This is the fix for NSURLErrorDomain -1011.
    func startWorkerRelayAsJoinerWithToken(roomCode: String, roomToken: String, signaling: WorkerSignaling) async throws {
        logger.info("Accepting invite — joining room \(roomCode) with token")

        let generation = UUID()
        connectionGeneration = generation
        forceTransitionToRequesting()

        let metricsToken = await ConnectionMetrics.shared.begin(
            type: .relayWorker, role: .joiner
        )

        // Open WebSocket FIRST with the invite-provided token (no race).
        signaling.joinRoom(code: roomCode, token: roomToken)

        // Fetch ICE in parallel; fall back to STUN if fails.
        let iceResult = try? await signaling.requestICECredentials(roomCode: roomCode)

        await launchJoinerSession(
            roomCode: roomCode,
            signaling: signaling,
            iceResult: iceResult,
            generation: generation,
            metricsToken: metricsToken
        )
    }

    /// Construct and start a joiner `RelaySession` and install it as the active session.
    /// Pre-condition: caller has already called `signaling.joinRoom(code:token:)`.
    @MainActor
    private func launchJoinerSession(
        roomCode: String,
        signaling: WorkerSignaling,
        iceResult: WorkerSignaling.ICEResult?,
        generation: UUID,
        metricsToken: ConnectionMetrics.Token
    ) async {
        // Cancel any prior in-flight session before holding the new one.
        activeRelaySession?.cancel(reason: "supersededByJoiner")
        activeRelaySession = nil

        let session = RelaySession(
            roomCode: roomCode,
            role: .joiner,
            signaling: signaling,
            metricsToken: metricsToken,
            iceResult: iceResult,
            logger: logger
        )
        session.onConnected = { [weak self] transport in
            guard let self, self.connectionGeneration == generation else { return }
            self.completeRelayConnection(transport: transport, roomCode: roomCode)
        }
        session.onFailed = { [weak self] reason in
            guard let self, self.connectionGeneration == generation else { return }
            self.transition(to: .failed(reason: reason))
        }
        activeRelaySession = session
        await session.start()
    }

    /// Stores the current invite-accept task so it can be cancelled if superseded.
    private var activeInviteTask: Task<Void, Never>?

    /// Initiate a relay invite to a known device. Creates a room, pushes the invite via
    /// the worker (WS inbox or APNs fallback), and starts the relay session as creator.
    /// The peer side receives a `RelayInvite` and can one-tap accept — no manual code.
    func inviteKnownDevice(_ device: DeviceRecord) async {
        guard let peerDeviceId = device.peerDeviceId else {
            await MainActor.run { inviteError = String(localized: "Device ID not yet known") }
            return
        }
        await MainActor.run {
            invitingDeviceId = device.id
            inviteError = nil
        }
        do {
            let signaling = WorkerSignaling()
            let room = try await signaling.createRoom()
            guard let roomToken = room.roomToken else {
                await MainActor.run {
                    inviteError = String(localized: "Server did not return room token")
                    invitingDeviceId = nil
                }
                return
            }
            let senderName = await MainActor.run { UIDevice.current.name }
            try await signaling.sendInvite(
                toDeviceId: peerDeviceId,
                roomCode: room.roomCode,
                roomToken: roomToken,
                senderName: senderName,
                senderId: DeviceIdentity.deviceId
            )
            await MainActor.run {
                invitingDeviceId = nil
                startWorkerRelayAsCreator(
                    roomCode: room.roomCode,
                    roomToken: roomToken,
                    signaling: signaling
                )
            }
        } catch {
            await MainActor.run {
                inviteError = error.localizedDescription
                invitingDeviceId = nil
            }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await MainActor.run {
                if inviteError == error.localizedDescription { inviteError = nil }
            }
        }
    }

    /// Accept a relay invite — creates signaling and joins as the answerer.
    /// Dedups concurrent delivery from WebSocket inbox + APNs within a 60s window.
    func acceptRelayInvite(_ invite: RelayInvite) {
        guard invite.hasToken else {
            logger.info("Ignoring invite without token (waiting for inbox WS flush)")
            return
        }

        let now = Date()
        inProgressInviteRoomCodes = inProgressInviteRoomCodes.filter { now.timeIntervalSince($0.value) < inviteDedupTTL }
        guard inProgressInviteRoomCodes[invite.roomCode] == nil else {
            logger.info("Ignoring duplicate invite accept for room \(invite.roomCode)")
            return
        }
        inProgressInviteRoomCodes[invite.roomCode] = now

        // Cancel any prior in-flight invite negotiation
        activeInviteTask?.cancel()

        let baseURL = UserDefaults.standard.string(forKey: "peerDropWorkerURL")
            .flatMap(URL.init(string:))
            ?? URL(string: "https://peerdrop-signal.hanfourhuang.workers.dev")!
        let signaling = WorkerSignaling(baseURL: baseURL)
        activeInviteTask = Task {
            do {
                try await self.startWorkerRelayAsJoinerWithToken(
                    roomCode: invite.roomCode,
                    roomToken: invite.roomToken,
                    signaling: signaling
                )
            } catch {
                await MainActor.run { self.inProgressInviteRoomCodes[invite.roomCode] = nil }
                ErrorReporter.report(
                    error: error.localizedDescription,
                    context: "invite.accept",
                    extras: ["roomCode": invite.roomCode, "senderId": invite.senderId]
                )
            }
        }
    }

    /// Complete the relay connection after DataChannel opens.
    private func completeRelayConnection(transport: DataChannelTransport, roomCode: String) {
        logger.info("Relay DataChannel open for room: \(roomCode)")

        let peerID = "relay-\(roomCode)"
        let remoteFingerprint = transport.client.remoteDTLSFingerprint
        let localFingerprint = transport.client.localDTLSFingerprint
        let peerIdentity = PeerIdentity(id: peerID, displayName: "Relay Peer", certificateFingerprint: remoteFingerprint)

        let peerConnection = PeerConnection(
            peerID: peerID,
            transport: transport,
            peerIdentity: peerIdentity,
            localIdentity: localIdentity,
            state: .connected
        )

        addConnection(peerConnection)
        focusedPeerID = peerID

        // Force to .connected — state may be .requesting or other states
        if case .requesting = state {
            transition(to: .connecting)
            transition(to: .connected)
        } else {
            // Fallback: force through valid path
            forceTransitionToRequesting()
            transition(to: .connecting)
            transition(to: .connected)
        }

        // Check if peer is already known (skip PIN verification)
        let needsPIN: Bool
        if let remoteFP = remoteFingerprint,
           RelayAuthenticator.isKnownDevice(peerID: peerID, remoteFingerprint: remoteFP, store: deviceStore) {
            logger.info("Relay peer is known device — skipping PIN verification")
            needsPIN = false
        } else if let localFP = localFingerprint, let remoteFP = remoteFingerprint {
            // New device — show PIN verification, defer handshake
            let pin = RelayAuthenticator.derivePIN(localFingerprint: localFP, remoteFingerprint: remoteFP)
            pendingRelayPIN = RelayPINRequest(pin: pin, peerID: peerID, remoteFingerprint: remoteFP)
            pendingRelayPeerConnection = peerConnection
            needsPIN = true
        } else {
            needsPIN = false
        }

        guard !needsPIN else { return }

        // Start the handshake — send HELLO (startReceiving already called by addConnection)
        startRelayHandshake(peerConnection)
    }

    /// Confirm PIN verification — store fingerprint and begin handshake.
    func confirmRelayPIN() {
        guard let request = pendingRelayPIN else { return }
        RelayAuthenticator.storeFingerprint(request.remoteFingerprint, for: request.peerID, store: deviceStore)
        pendingRelayPIN = nil

        // Resume the deferred handshake
        if let pc = pendingRelayPeerConnection {
            pendingRelayPeerConnection = nil
            startRelayHandshake(pc)
        }
    }

    /// Reject PIN verification — disconnect the relay peer.
    func rejectRelayPIN() {
        guard let request = pendingRelayPIN else { return }
        pendingRelayPIN = nil
        pendingRelayPeerConnection = nil
        Task { await disconnect(from: request.peerID) }
    }

    /// Send HELLO and start the session timer for a relay connection.
    private func startRelayHandshake(_ peerConnection: PeerConnection) {
        Task {
            do {
                let hello = try PeerMessage.hello(identity: localIdentity)
                try await peerConnection.sendMessage(hello)
                // Exchange stable device ID so future invites can route directly.
                let idExchange = try PeerMessage.deviceIdExchange(
                    deviceId: DeviceIdentity.deviceId,
                    senderID: localIdentity.id
                )
                try await peerConnection.sendMessage(idExchange)
            } catch {
                logger.error("Relay handshake failed: \(error.localizedDescription)")
                transition(to: .failed(reason: error.localizedDescription))
            }
        }
        startRelaySessionTimer(peerID: peerConnection.id, ttlSeconds: 900)
    }

    /// Start a timer that disconnects the relay after TTL expires.
    private func startRelaySessionTimer(peerID: String, ttlSeconds: Int) {
        relaySessionTimer?.cancel()
        relaySessionTimer = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(ttlSeconds) * 1_000_000_000)
                guard let self else { return }
                await MainActor.run {
                    self.statusToast = "Relay session expired"
                    Task { await self.disconnect(from: peerID) }
                }
            } catch {
                // Task cancelled
            }
        }
    }

    func disconnect() {
        logger.info("disconnect() called — state=\(String(describing: self.state)), activeConnection=\(self.activeConnection != nil ? "exists" : "nil")")
        cancelTimeouts()
        connectionGeneration = UUID()
        // Cancel any in-flight relay session so its signaling WS closes; the
        // RelaySession deinit would also do this when the reference is dropped,
        // but explicit cancel guarantees synchronous cleanup.
        activeRelaySession?.cancel(reason: "managerDisconnect")
        activeRelaySession = nil
        // Capture and nil-out the connection BEFORE cancelling so the receive
        // loop sees activeConnection == nil and doesn't race to .failed.
        let connection = activeConnection
        activeConnection = nil
        Task {
            // Disconnect all multi-peer connections
            for (peerID, peerConn) in self.connections {
                await peerConn.disconnect(sendMessage: false)
                await MainActor.run { self.removeConnection(peerID: peerID) }
            }
            // Legacy single connection cleanup
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
        if peerID == focusedPeerID {
            activeConnection = nil
        }
        await peerConn.disconnect()
        nearbyInteractionManager?.stopSession(for: peerID)
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
        consentMonitorTask?.cancel()
        consentMonitorTask = nil
        consentTimeoutTask?.cancel()
        consentTimeoutTask = nil
        pendingRelayPeerConnection = nil
        pendingRelayPIN = nil
        pendingIncomingRequest = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        if let peerID = focusedPeerID {
            failedPeers.removeValue(forKey: peerID)
        }
        focusedPeerID = nil
        nearbyInteractionManager?.stopAllSessions()
        relaySessionTimer?.cancel()
        relaySessionTimer = nil
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

        case .niTokenOffer:
            guard let payload = message.payload else { return }
            nearbyInteractionManager?.handleTokenOffer(payload, from: peerID) { [weak self] responseData in
                guard let self else { return }
                let response = PeerMessage(type: .niTokenResponse, payload: responseData, senderID: self.localIdentity.id)
                Task {
                    do { try await peerConnection.sendMessage(response) }
                    catch { logger.warning("Failed to send NI token response: \(error.localizedDescription)") }
                }
            }

        case .niTokenResponse:
            guard let payload = message.payload else { return }
            nearbyInteractionManager?.handleTokenResponse(payload, from: peerID)

        case .clipboardSync:
            guard FeatureSettings.isClipboardSyncEnabled else { return }
            guard let payload = try? message.decodePayload(ClipboardSyncPayload.self) else {
                logger.warning("Failed to decode ClipboardSyncPayload")
                return
            }
            clipboardSyncManager.applyReceivedClipboard(payload)
            NotificationManager.shared.postChatMessage(
                from: peerConnection.peerIdentity.displayName,
                text: NSLocalizedString("Clipboard synced", comment: "")
            )

        case .messageEdit:
            guard FeatureSettings.isChatEnabled else { return }
            guard let payload = try? message.decodePayload(MessageEditPayload.self) else {
                logger.warning("Failed to decode MessageEditPayload")
                return
            }
            chatManager.applyEdit(messageID: payload.messageID, newText: payload.newText, editedAt: payload.editedAt, peerID: peerID)

        case .messageDelete:
            guard FeatureSettings.isChatEnabled else { return }
            guard let payload = try? message.decodePayload(MessageDeletePayload.self) else {
                logger.warning("Failed to decode MessageDeletePayload")
                return
            }
            chatManager.applyDelete(messageID: payload.messageID, peerID: peerID)

        case .fileResume:
            guard let payload = try? message.decodePayload(FileResumePayload.self) else {
                logger.warning("Failed to decode FileResumePayload")
                return
            }
            peerConnection.fileTransferSession?.handleResumeRequest(payload, peerConnection: peerConnection, senderID: localIdentity.id)

        case .fileResumeAck:
            guard let payload = try? message.decodePayload(FileResumeAckPayload.self) else {
                logger.warning("Failed to decode FileResumeAckPayload")
                return
            }
            peerConnection.fileTransferSession?.handleResumeAck(payload)

        case .deviceIdExchange:
            guard let payload = try? message.decodePayload(DeviceIdExchangePayload.self) else {
                logger.warning("Failed to decode DeviceIdExchangePayload")
                return
            }
            deviceStore.updatePeerDeviceId(for: peerConnection.id, deviceId: payload.deviceId)
            logger.info("Stored peerDeviceId for \(peerConnection.id): \(payload.deviceId.prefix(8))")

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
                // v5.1: capability flag is in the connectionAccept payload.
                triggerSecureChannelNegotiation(for: peerConnection)
            }

            // State machine requires requesting → connecting → connected
            transition(to: .connecting)
            transition(to: .connected)
            recordConnectedDevice()
            resetReconnectAttempts()
            if let identity = peerIdentity {
                recordConnectionSuccess(for: identity.id)
            }

            // Start Nearby Interaction for legacy path
            if let peerID = peerIdentity?.id, let peerConn = connections[peerID] {
                startNearbyInteractionSession(for: peerID, via: peerConn)
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
                    // v5.1: relay path swaps in the real identity here
                    // (replacing the placeholder). Now we know whether the
                    // peer supports LocalSecureChannel — trigger.
                    triggerSecureChannelNegotiation(for: peerConn)
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
                    triggerSecureChannelNegotiation(for: peerConnection)
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

        case .niTokenOffer, .niTokenResponse:
            // NI tokens in legacy path — only handled in multi-connection path
            break

        case .clipboardSync:
            guard FeatureSettings.isClipboardSyncEnabled else { return }
            guard let payload = try? message.decodePayload(ClipboardSyncPayload.self) else {
                logger.warning("Failed to decode ClipboardSyncPayload")
                return
            }
            clipboardSyncManager.applyReceivedClipboard(payload)

        case .messageEdit:
            guard FeatureSettings.isChatEnabled else { return }
            guard let payload = try? message.decodePayload(MessageEditPayload.self) else { return }
            chatManager.applyEdit(messageID: payload.messageID, newText: payload.newText, editedAt: payload.editedAt, peerID: message.senderID)

        case .messageDelete:
            guard FeatureSettings.isChatEnabled else { return }
            guard let payload = try? message.decodePayload(MessageDeletePayload.self) else { return }
            chatManager.applyDelete(messageID: payload.messageID, peerID: message.senderID)

        case .fileResume, .fileResumeAck:
            // File resume only supported in multi-connection path
            break

        case .deviceIdExchange:
            // Legacy path — relay peers go through handleMessageForPeer, ignore here.
            break

        case .secureHandshake, .secureEnvelope:
            // Secure-channel frames are handled inside PeerConnection's
            // receive loop before they reach this legacy single-connection
            // path. If one slips through here, it's already too late to
            // act on — log + drop.
            logger.warning("handleMessageLegacy received secure-channel frame; ignoring")
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

    // MARK: - Clipboard Sync

    func sendClipboardSync(_ payload: ClipboardSyncPayload, to peerID: String) {
        guard FeatureSettings.isClipboardSyncEnabled else { return }
        guard let peerConn = connection(for: peerID) else { return }
        guard let msg = try? PeerMessage.clipboardSync(payload, senderID: localIdentity.id) else {
            logger.warning("Failed to create PeerMessage for clipboardSync")
            return
        }
        Task {
            do { try await peerConn.sendMessage(msg) }
            catch { logger.warning("Failed to send clipboard sync: \(error.localizedDescription)") }
        }
    }

    func sendClipboardSyncToAll(_ payload: ClipboardSyncPayload) {
        for (peerID, peerConn) in connections where peerConn.state.isConnected {
            sendClipboardSync(payload, to: peerID)
        }
    }

    // MARK: - Message Edit / Delete

    func sendMessageEdit(messageID: String, newText: String, to peerID: String, groupID: String? = nil) {
        guard FeatureSettings.isChatEnabled else { return }
        guard let peerConn = connection(for: peerID) else { return }

        let payload = MessageEditPayload(messageID: messageID, newText: newText, groupID: groupID)
        guard let msg = try? PeerMessage.messageEdit(payload, senderID: localIdentity.id) else {
            logger.warning("Failed to create PeerMessage for messageEdit")
            return
        }
        Task {
            do { try await peerConn.sendMessage(msg) }
            catch { logger.warning("Failed to send message edit: \(error.localizedDescription)") }
        }

        chatManager.applyEdit(messageID: messageID, newText: newText, editedAt: Date(), peerID: peerID)
    }

    func sendMessageDelete(messageID: String, to peerID: String, groupID: String? = nil) {
        guard FeatureSettings.isChatEnabled else { return }
        guard let peerConn = connection(for: peerID) else { return }

        let payload = MessageDeletePayload(messageID: messageID, groupID: groupID)
        guard let msg = try? PeerMessage.messageDelete(payload, senderID: localIdentity.id) else {
            logger.warning("Failed to create PeerMessage for messageDelete")
            return
        }
        Task {
            do { try await peerConn.sendMessage(msg) }
            catch { logger.warning("Failed to send message delete: \(error.localizedDescription)") }
        }

        chatManager.applyDelete(messageID: messageID, peerID: peerID)
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

    // MARK: - Trust Verification

    /// Check a peer's identity against the trusted contact store.
    /// Called after receiving a peer's hello message during connection setup.
    func checkPeerTrust(peerIdentity: PeerIdentity) {
        guard let peerPublicKey = peerIdentity.identityPublicKey else {
            logger.info("Peer \(peerIdentity.displayName) has no identity public key (legacy client)")
            return
        }

        // Validate public key is a valid 32-byte Curve25519 point
        guard peerPublicKey.count == 32,
              let _ = try? CryptoKit.Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey) else {
            logger.warning("Invalid public key from \(peerIdentity.displayName)")
            return
        }

        if let existingContact = trustedContactStore.find(byPublicKey: peerPublicKey) {
            // Known contact, key matches — trust level unchanged
            logger.info("Peer \(peerIdentity.displayName) recognized as trusted contact: \(existingContact.trustLevel.rawValue)")
        } else if let contactByDeviceId = trustedContactStore.find(byDeviceId: peerIdentity.id) {
            // Same device ID but different key — KEY CHANGE WARNING
            let oldFingerprint = contactByDeviceId.keyFingerprint
            let newContact = TrustedContact(
                displayName: peerIdentity.displayName,
                identityPublicKey: peerPublicKey,
                trustLevel: .unknown
            )
            let newFingerprint = newContact.keyFingerprint

            logger.warning("KEY CHANGE detected for \(peerIdentity.displayName) (device: \(peerIdentity.id))!")
            pendingKeyChangeAlert = KeyChangeAlertInfo(
                contactName: peerIdentity.displayName,
                contactId: contactByDeviceId.id,
                oldFingerprint: oldFingerprint,
                newFingerprint: newFingerprint,
                newPublicKey: peerPublicKey
            )
        } else {
            // Unknown peer — add as unknown trust level
            let newContact = TrustedContact(
                deviceId: peerIdentity.id,
                displayName: peerIdentity.displayName,
                identityPublicKey: peerPublicKey,
                trustLevel: .unknown
            )
            trustedContactStore.add(newContact)
            logger.info("New contact added: \(peerIdentity.displayName) (unknown trust)")
        }
    }

    // MARK: - LocalSecureChannel (v5.1 audit-#13)

    /// Kick off the LocalSecureChannel handshake on a peer connection
    /// whose `peerIdentity` is now fully populated. Wires the
    /// `onSecureChannelEstablished` callback so the post-handshake
    /// fingerprint can be pinned against `TrustedContactStore`. Safe to
    /// call more than once on the same connection — `initiateSecureHandshake`
    /// no-ops once state has left `.disabled`, so trigger points scattered
    /// across hello/connectionAccept/acceptConnection can all call without
    /// risk of starting a second handshake.
    private func triggerSecureChannelNegotiation(for peerConnection: PeerConnection) {
        peerConnection.onSecureChannelEstablished = { [weak self, weak peerConnection] fingerprint in
            Task { @MainActor in
                guard let self, let peerConnection else { return }
                self.handleSecureChannelEstablished(for: peerConnection, fingerprint: fingerprint)
            }
        }
        Task { [weak peerConnection] in
            guard let peerConnection else { return }
            await peerConnection.startSecureChannelNegotiation(
                peerSupportsSecureChannel: peerConnection.peerIdentity.supportsSecureChannel
            )
        }
    }

    /// Run TOFU pinning after `LocalSecureChannel` establishes.
    ///
    /// `checkPeerTrust` runs earlier (off the hello payload) and is
    /// responsible for ADDING a record. This callback's job is to set
    /// `pinningVerdict` so the UI lock chip reflects the matched/mismatch
    /// state, and to surface the existing `KeyChangeAlertInfo` flow if a
    /// silent rotation slipped past checkPeerTrust.
    @MainActor
    private func handleSecureChannelEstablished(for peerConnection: PeerConnection, fingerprint: String) {
        let identity = peerConnection.peerIdentity
        guard let peerPublicKey = identity.identityPublicKey else {
            logger.warning("Secure channel up but peer has no identityPublicKey — cannot pin")
            return
        }
        if trustedContactStore.find(byPublicKey: peerPublicKey) != nil {
            peerConnection.setPinningVerdict(.matched)
            logger.info("Pinning: matched existing contact for \(identity.displayName, privacy: .public)")
        } else if let stored = trustedContactStore.find(byDeviceId: identity.id) {
            peerConnection.setPinningVerdict(.mismatch(stored: stored.keyFingerprint, received: fingerprint))
            logger.warning("Pinning: KEY MISMATCH for \(identity.displayName, privacy: .public) — stored=\(stored.keyFingerprint, privacy: .public) received=\(fingerprint, privacy: .public)")
        } else {
            peerConnection.setPinningVerdict(.firstTrust)
            logger.info("Pinning: first-trust (TOFU) for \(identity.displayName, privacy: .public)")
            // `secureChannel` is non-nil here — the callback fires only after
            // `establish()` materializes the channel. The SAS is computed
            // during establish() and immutable for the channel's lifetime, so
            // capturing it now is safe.
            let sas = peerConnection.secureChannel?.shortAuthenticationString
            surfaceLocalFirstTrust(
                identity: identity,
                peerPublicKey: peerPublicKey,
                fingerprint: fingerprint,
                sas: sas)
        }
    }

    /// Set the published prompt that drives `FirstContactVerificationSheet`
    /// for the local-Wi-Fi path. Idempotent: a second firstTrust event on the
    /// same fingerprint while the prompt is already up is dropped (the active
    /// sheet already references that peer). Concurrent firstTrust events on
    /// *different* peers are silently dropped in S1 — the user resolves one
    /// sheet at a time and the lock chip on ConnectedTab still flags the
    /// other peers as `.firstTrust`. A proper queue lands with S2/S3.
    private func surfaceLocalFirstTrust(
        identity: PeerIdentity,
        peerPublicKey: Data,
        fingerprint: String,
        sas: String?
    ) {
        if let existing = pendingLocalFirstTrust,
           existing.senderIdentityKey == peerPublicKey {
            return  // already prompting the user about this peer
        }
        guard pendingLocalFirstTrust == nil else {
            logger.info("Skipping local first-trust prompt for \(identity.displayName, privacy: .public) — another prompt already active")
            return
        }
        pendingLocalFirstTrust = PendingFirstContact(
            fingerprint: fingerprint,
            senderDisplayName: identity.displayName,
            senderIdentityKey: peerPublicKey,
            sas: sas
        )
        logger.info("Surfaced local first-trust prompt for \(identity.displayName, privacy: .public)")
    }

    /// User approved a local-Wi-Fi first-trust prompt. Elevates the existing
    /// `.unknown` TrustedContact (added silently by `checkPeerTrust` during
    /// hello) to `.linked`, flips the live connection's pinning verdict to
    /// `.matched` so the lock chip turns green, and clears the prompt.
    /// Connection itself is unchanged — the user only authorised continuing
    /// with this peer, not interrupting the live session.
    func approveLocalFirstTrust(fingerprint: String) {
        guard let current = pendingLocalFirstTrust, current.fingerprint == fingerprint else { return }
        pendingLocalFirstTrust = nil

        if let contact = trustedContactStore.find(byPublicKey: current.senderIdentityKey) {
            trustedContactStore.updateTrustLevel(for: contact.id, to: .linked)
            logger.info("Elevated \(contact.displayName, privacy: .public) to .linked after local first-trust approval")
        } else {
            // Defensive: checkPeerTrust runs earlier in the connection flow,
            // so the .unknown record should already exist. If something
            // raced and removed it (unlikely), recreate at .linked directly.
            let newContact = TrustedContact(
                deviceId: nil,
                displayName: current.senderDisplayName,
                identityPublicKey: current.senderIdentityKey,
                trustLevel: .linked
            )
            trustedContactStore.add(newContact)
            logger.info("Added missing contact at .linked after local first-trust approval")
        }
        if let conn = liveConnection(matchingPublicKey: current.senderIdentityKey) {
            conn.setPinningVerdict(.matched)
        }
    }

    /// User blocked a local-Wi-Fi first-trust prompt. Marks the contact as
    /// blocked, tears down the live peer connection, and clears the prompt.
    /// `isBlocked` is the user-facing block flag; the underlying contact
    /// record persists for the audit trail so a future reconnect still
    /// surfaces the block (instead of falling back through TOFU again).
    func blockLocalFirstTrust(fingerprint: String) {
        guard let current = pendingLocalFirstTrust, current.fingerprint == fingerprint else { return }
        pendingLocalFirstTrust = nil

        if let contact = trustedContactStore.find(byPublicKey: current.senderIdentityKey) {
            trustedContactStore.setBlocked(contact.id, blocked: true)
            logger.info("Blocked \(contact.displayName, privacy: .public) after local first-trust rejection")
        }
        if let (peerID, _) = liveConnectionEntry(matchingPublicKey: current.senderIdentityKey) {
            Task { await disconnect(from: peerID) }
        }
    }

    /// Find the live PeerConnection whose peer identity matches a public key.
    /// Used by the local first-trust handlers to flip verdict / disconnect.
    private func liveConnection(matchingPublicKey publicKey: Data) -> PeerConnection? {
        liveConnectionEntry(matchingPublicKey: publicKey)?.connection
    }

    private func liveConnectionEntry(matchingPublicKey publicKey: Data) -> (peerID: String, connection: PeerConnection)? {
        for (peerID, conn) in connections {
            if conn.peerIdentity.identityPublicKey == publicKey {
                return (peerID, conn)
            }
        }
        return nil
    }

    /// User chose to block the contact whose key changed
    func handleKeyChangeBlock() {
        guard let alert = pendingKeyChangeAlert else { return }
        trustedContactStore.setBlocked(alert.contactId, blocked: true)
        pendingKeyChangeAlert = nil
    }

    /// User chose to accept the new key (sets trust to .linked — user actively accepted)
    func handleKeyChangeAccept() {
        guard let alert = pendingKeyChangeAlert else { return }
        trustedContactStore.updatePublicKey(
            for: alert.contactId,
            newKey: alert.newPublicKey,
            trustLevel: .linked,
            reason: .userAcceptedNewKey
        )
        pendingKeyChangeAlert = nil
    }

    /// User chose to verify later (stays at .unknown until face-to-face verification)
    func handleKeyChangeVerifyLater() {
        guard let alert = pendingKeyChangeAlert else { return }
        trustedContactStore.updatePublicKey(
            for: alert.contactId,
            newKey: alert.newPublicKey,
            trustLevel: .unknown,
            reason: .userAcceptedNewKey
        )
        pendingKeyChangeAlert = nil
    }

    // MARK: - Tailnet Helpers

    private func extractRemoteHost(from endpoint: NWEndpoint) -> String? {
        switch endpoint {
        case .hostPort(let host, _):
            switch host {
            case .ipv4(let addr): return "\(addr)"
            case .ipv6(let addr): return "\(addr)"
            case .name(let s, _): return s
            @unknown default: return nil
            }
        default: return nil
        }
    }

    private func isTailnetIP(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 100 && parts[1] >= 64 && parts[1] <= 127
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
