import Foundation
import Network
import Combine
import SwiftUI
import UIKit
import os

private let logger = Logger(subsystem: "com.peerdrop.app", category: "ConnectionManager")


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
    @Published private(set) var connectedPeer: PeerIdentity?
    @Published var transferHistory: [TransferRecord] = [] {
        didSet { saveTransferHistory() }
    }
    @Published var latestToast: TransferRecord?
    @Published var statusToast: String?

    // MARK: - Internal

    private var discoveryCoordinator: DiscoveryCoordinator?
    private var bonjourDiscovery: BonjourDiscovery?
    private var activeConnection: NWConnection?
    private var cancellables = Set<AnyCancellable>()
    private let localIdentity: PeerIdentity
    let certificateManager = CertificateManager()
    private(set) var lastConnectedPeer: DiscoveredPeer?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var requestingTimeoutTask: Task<Void, Never>?
    private var connectingTimeoutTask: Task<Void, Never>?
    private var consentMonitorTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    /// Tracks the current connection attempt so stale callbacks are ignored.
    private var connectionGeneration: UUID = UUID()

    // MARK: - Submanagers (set after init)

    private(set) var fileTransfer: FileTransfer?
    private(set) var voiceCallManager: VoiceCallManager?
    let deviceStore = DeviceRecordStore()
    let chatManager = ChatManager()

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
    }

    /// Call once after init to wire up CallKit (requires AppDelegate reference).
    func configureVoiceCalling(callKitManager: CallKitManager) {
        self.voiceCallManager = VoiceCallManager(connectionManager: self, callKitManager: callKitManager)
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
            print("[ConnectionManager] Invalid transition: \(state) → \(newState)")
            return
        }
        let oldState = state
        logger.info("State: \(String(describing: oldState)) → \(String(describing: newState))")
        state = newState
        triggerHaptic(for: newState)

        // Heartbeat management
        switch newState {
        case .connected:
            startHeartbeat()
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
    }

    func stopDiscovery() {
        discoveryCoordinator?.stop()
        discoveryCoordinator = nil
        bonjourDiscovery = nil
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
        connectedPeer = nil
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

    /// Attempt to reconnect to the last connected peer.
    func reconnect() {
        guard let peer = lastConnectedPeer else { return }
        requestConnection(to: peer)
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
            if case .idle = state {
                // Resume discovery if we were idle
            } else if case .discovering = state {
                restartDiscovery()
            }
        case .background:
            // Keep alive if transferring or on a call
            if case .transferring = state {
                beginBackgroundTask()
            } else if case .voiceCall = state {
                beginBackgroundTask()
            } else {
                stopDiscovery()
            }
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    private func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
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
                        try? await self.sendMessage(ping)
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
                    print("[ConnectionManager] Connection request timed out after 15s")
                    // Notify the acceptor so they can dismiss the consent sheet
                    if let conn = self.activeConnection {
                        let cancel = PeerMessage.connectionCancel(senderID: self.localIdentity.id)
                        try? await conn.sendMessage(cancel)
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
                    print("[ConnectionManager] Connection setup timed out after 10s")
                    // Notify the acceptor so they can dismiss the consent sheet
                    if let conn = self.activeConnection {
                        let cancel = PeerMessage.connectionCancel(senderID: self.localIdentity.id)
                        try? await conn.sendMessage(cancel)
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
        // If already connected to this peer, don't create a duplicate connection
        if let last = lastConnectedPeer, last.id == peer.id,
           case .connected = state {
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
                logger.error("Connection failed: \(error.localizedDescription)")
                cancelTimeouts()
                activeConnection?.cancel()
                activeConnection = nil
                transition(to: .failed(reason: error.localizedDescription))
                if discoveryCoordinator == nil {
                    restartDiscovery()
                }
            }
        }
    }

    // MARK: - Incoming Connection

    private func handleIncomingConnection(_ connection: NWConnection) {
        logger.info("Incoming connection from: \(String(describing: connection.endpoint))")

        // Reject if we're already handling a connection or are connected
        guard activeConnection == nil else {
            logger.info("Already have active connection, rejecting incoming from: \(String(describing: connection.endpoint))")
            connection.cancel()
            return
        }

        connection.start(queue: .global(qos: .userInitiated))
        activeConnection = connection

        connection.stateUpdateHandler = { [weak self] state in
            logger.info("Incoming NWConnection state: \(String(describing: state))")
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .failed, .cancelled:
                    if self.pendingIncomingRequest != nil {
                        self.pendingIncomingRequest = nil
                        self.statusToast = "Connection request expired"
                    }
                    // Always clean up stale activeConnection
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
                let requestMsg = try await connection.receiveMessage()

                guard requestMsg.type == .connectionRequest else {
                    logger.error("Expected connectionRequest, got: \(String(describing: requestMsg.type))")
                    connection.cancel()
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
                activeConnection = nil
                if case .incomingRequest = state {
                    transition(to: .discovering)
                }
            }
        }
    }

    /// Listens for messages (e.g. connectionCancel) while the consent sheet is showing.
    /// Without active reads, NWConnection won't detect remote close promptly.
    private func startConsentMonitor(on connection: NWConnection) {
        consentMonitorTask?.cancel()
        consentMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.pendingIncomingRequest != nil else { break }
                do {
                    let message = try await connection.receiveMessage()
                    // Process the message on the main actor
                    await MainActor.run {
                        self.handleMessage(message)
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
    }

    // MARK: - Consent Response

    func acceptConnection() {
        guard let request = pendingIncomingRequest else { return }
        consentMonitorTask?.cancel()
        consentMonitorTask = nil
        // Verify the connection is still alive before attempting to accept
        guard request.connection.state == .ready else {
            pendingIncomingRequest = nil
            activeConnection = nil
            statusToast = "Connection is no longer available"
            transition(to: .discovering)
            return
        }
        pendingIncomingRequest = nil
        connectedPeer = request.peerIdentity
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
                transition(to: .connected)
                recordConnectedDevice()
                startReceiving()
            } catch {
                cancelTimeouts()
                activeConnection?.cancel()
                activeConnection = nil
                transition(to: .failed(reason: error.localizedDescription))
                if discoveryCoordinator == nil {
                    restartDiscovery()
                }
            }
        }
    }

    func rejectConnection() {
        guard let request = pendingIncomingRequest else { return }
        consentMonitorTask?.cancel()
        consentMonitorTask = nil
        pendingIncomingRequest = nil

        Task {
            let reject = PeerMessage.connectionReject(senderID: localIdentity.id)
            try? await request.connection.sendMessage(reject)
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
                try? await connection.sendMessage(msg)
                connection.cancel()
            }
            cleanupAfterDisconnect()
        }
    }

    /// Cleanup after the local user initiates disconnect.
    private func cleanupAfterDisconnect() {
        activeConnection = nil
        connectedPeer = nil
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
                    handleMessage(message)
                } catch {
                    logger.error("Receive loop error: \(error.localizedDescription)")
                    // Only handle if this loop still owns the connection
                    guard connectionGeneration == generation, activeConnection != nil else { break }
                    fileTransfer?.handleConnectionFailure()
                    activeConnection = nil
                    // Keep connectedPeer so UI shows who we lost connection with
                    transition(to: .failed(reason: error.localizedDescription))
                    if discoveryCoordinator == nil {
                        restartDiscovery()
                    }
                    break
                }
            }
        }
    }

    private func handleMessage(_ message: PeerMessage) {
        logger.info("handleMessage: \(String(describing: message.type)) from \(message.senderID)")
        switch message.type {
        case .connectionAccept:
            cancelTimeouts()
            if let payload = message.payload,
               let identity = try? JSONDecoder().decode(PeerIdentity.self, from: payload) {
                connectedPeer = identity
            }
            // State machine requires requesting → connecting → connected
            if case .requesting = state {
                transition(to: .connecting)
            }
            transition(to: .connected)
            recordConnectedDevice()

        case .connectionReject:
            cancelTimeouts()
            activeConnection?.cancel()
            activeConnection = nil
            transition(to: .rejected)

        case .connectionCancel:
            // Initiator cancelled the request — dismiss consent sheet
            pendingIncomingRequest = nil
            activeConnection?.cancel()
            activeConnection = nil
            statusToast = "Connection request was cancelled"
            transition(to: .discovering)

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
                Task { try? await sendMessage(reject) }
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
                Task { try? await sendMessage(reject) }
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
                Task { try? await sendMessage(reject) }
                return
            }
            if let payload = try? message.decodePayload(TextMessagePayload.self) {
                chatManager.saveIncoming(
                    text: payload.text,
                    peerID: message.senderID,
                    peerName: connectedPeer?.displayName ?? "Unknown"
                )
                NotificationManager.shared.postChatMessage(from: connectedPeer?.displayName ?? "Unknown", text: payload.text)
            }

        case .mediaMessage:
            guard FeatureSettings.isChatEnabled else {
                let reject = PeerMessage.chatReject(senderID: localIdentity.id, reason: "featureDisabled")
                Task { try? await sendMessage(reject) }
                return
            }
            if let payload = try? message.decodePayload(MediaMessagePayload.self) {
                chatManager.saveIncomingMedia(
                    payload: payload,
                    fileData: Data(),
                    peerID: message.senderID,
                    peerName: connectedPeer?.displayName ?? "Unknown"
                )
                NotificationManager.shared.postChatMessage(from: connectedPeer?.displayName ?? "Unknown", text: payload.fileName)
            }
        case .chatReject:
            // Remote peer has chat disabled — mark last outgoing message as failed
            if let peerID = connectedPeer?.id {
                let reason = (try? message.decodePayload(RejectionPayload.self))?.reason
                let errorText = reason == "featureDisabled" ? "Peer has chat disabled" : "Message rejected"
                chatManager.markLastOutgoingAsFailed(peerID: peerID, errorText: errorText)
            }

        case .hello:
            // During handshake, hello is handled inline. In the receive loop,
            // the acceptor sends a second hello after connectionAccept to share identity.
            if connectedPeer == nil, let payload = message.payload,
               let identity = try? JSONDecoder().decode(PeerIdentity.self, from: payload) {
                connectedPeer = identity
                recordConnectedDevice()
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
            Task { try? await sendMessage(pong) }

        case .pong:
            // Keepalive response received — connection is alive
            logger.debug("Heartbeat pong received from \(message.senderID)")
        }
    }

    private func handleConnectionStateChange(_ nwState: NWConnection.State) {
        switch nwState {
        case .setup:
            print("[ConnectionManager] Network connection initializing")
        case .waiting(let error):
            print("[ConnectionManager] Network connection waiting: \(error.localizedDescription)")
        case .preparing:
            print("[ConnectionManager] Network connection preparing (TLS handshake in progress)")
        case .ready:
            print("[ConnectionManager] Network connection established and ready")
        case .failed(let error):
            cancelTimeouts()
            fileTransfer?.handleConnectionFailure()
            activeConnection = nil
            transition(to: .failed(reason: error.localizedDescription))
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
            print("[ConnectionManager] Unknown network connection state")
        }
    }

    // MARK: - Chat

    func sendTextMessage(_ text: String) {
        guard FeatureSettings.isChatEnabled else { return }
        guard let peer = connectedPeer else { return }
        let payload = TextMessagePayload(text: text)
        guard let msg = try? PeerMessage.textMessage(payload, senderID: localIdentity.id) else { return }
        let saved = chatManager.saveOutgoing(text: text, peerID: peer.id, peerName: peer.displayName)
        Task {
            do {
                try await sendMessage(msg)
                await MainActor.run { chatManager.updateStatus(messageID: saved.id, status: .sent) }
            } catch {
                await MainActor.run { chatManager.updateStatus(messageID: saved.id, status: .failed) }
            }
        }
    }

    func sendMediaMessage(mediaType: MediaMessagePayload.MediaType, fileName: String, fileData: Data, mimeType: String, duration: Double?, thumbnailData: Data?) {
        guard FeatureSettings.isChatEnabled else { return }
        guard let peer = connectedPeer else { return }
        let payload = MediaMessagePayload(mediaType: mediaType, fileName: fileName, fileSize: Int64(fileData.count), mimeType: mimeType, duration: duration, thumbnailData: thumbnailData)
        guard let msg = try? PeerMessage.mediaMessage(payload, senderID: localIdentity.id) else { return }

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
                try await sendMessage(msg)
                await MainActor.run { chatManager.updateStatus(messageID: saved.id, status: .sent) }
            } catch {
                await MainActor.run { chatManager.updateStatus(messageID: saved.id, status: .failed) }
            }
        }
    }

    // MARK: - Send helpers

    func sendMessage(_ message: PeerMessage) async throws {
        guard let connection = activeConnection else {
            throw ConnectionError.notConnected
        }
        try await connection.sendMessage(message)
    }

    // MARK: - Transfer History Persistence

    private func loadTransferHistory() {
        guard let data = UserDefaults.standard.data(forKey: Self.transferHistoryKey),
              let decoded = try? JSONDecoder().decode([TransferRecord].self, from: data) else { return }
        transferHistory = decoded
    }

    private func saveTransferHistory() {
        guard let data = try? JSONEncoder().encode(transferHistory) else { return }
        UserDefaults.standard.set(data, forKey: Self.transferHistoryKey)
    }
}

enum ConnectionError: Error, LocalizedError {
    case notConnected
    case invalidState

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to a peer"
        case .invalidState: return "Invalid connection state"
        }
    }
}
