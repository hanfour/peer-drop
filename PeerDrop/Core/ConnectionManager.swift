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
    @Published var transferHistory: [TransferRecord] = []
    @Published var latestToast: TransferRecord?

    // MARK: - Internal

    private var discoveryCoordinator: DiscoveryCoordinator?
    private var bonjourDiscovery: BonjourDiscovery?
    private var activeConnection: NWConnection?
    private var cancellables = Set<AnyCancellable>()
    private let localIdentity: PeerIdentity
    let certificateManager = CertificateManager()
    private var lastConnectedPeer: DiscoveredPeer?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var requestingTimeoutTask: Task<Void, Never>?
    private var connectingTimeoutTask: Task<Void, Never>?

    // MARK: - Submanagers (set after init)

    private(set) var fileTransfer: FileTransfer?
    private(set) var voiceCallManager: VoiceCallManager?
    let deviceStore = DeviceRecordStore()
    let chatManager = ChatManager()

    init() {
        let certManager = CertificateManager()
        self.localIdentity = .local(certificateFingerprint: certManager.fingerprint)

        // Deferred init — fileTransfer needs `self`
        self.fileTransfer = FileTransfer(connectionManager: self)
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
        stopDiscovery()
        startDiscovery()
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

    private func startRequestingTimeout() {
        requestingTimeoutTask?.cancel()
        requestingTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 15_000_000_000) // 15 seconds
                guard let self, !Task.isCancelled else { return }
                if case .requesting = self.state {
                    print("[ConnectionManager] Connection request timed out after 15s")
                    self.activeConnection?.cancel()
                    self.activeConnection = nil
                    self.transition(to: .failed(reason: "Connection timed out"))
                }
            } catch {
                // Task was cancelled, nothing to do
            }
        }
    }

    private func startConnectingTimeout() {
        connectingTimeoutTask?.cancel()
        connectingTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
                guard let self, !Task.isCancelled else { return }
                if case .connecting = self.state {
                    print("[ConnectionManager] Connection setup timed out after 10s")
                    self.activeConnection?.cancel()
                    self.activeConnection = nil
                    self.transition(to: .failed(reason: "Connection setup timed out"))
                }
            } catch {
                // Task was cancelled, nothing to do
            }
        }
    }

    // MARK: - Connection Request (Outgoing)

    func requestConnection(to peer: DiscoveredPeer) {
        lastConnectedPeer = peer
        cancelTimeouts()
        // State machine requires discovering → peerFound → requesting
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

        connection.stateUpdateHandler = { [weak self] state in
            logger.info("NWConnection state: \(String(describing: state))")
            Task { @MainActor in
                self?.handleConnectionStateChange(state)
            }
        }

        connection.start(queue: .global(qos: .userInitiated))
        activeConnection = connection

        startRequestingTimeout()

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
                transition(to: .failed(reason: error.localizedDescription))
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

        connection.stateUpdateHandler = { state in
            logger.info("Incoming NWConnection state: \(String(describing: state))")
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
                transition(to: .incomingRequest)
                pendingIncomingRequest = IncomingRequest(
                    peerIdentity: peerIdentity,
                    connection: connection
                )
            } catch {
                logger.error("Incoming connection error: \(error.localizedDescription)")
                connection.cancel()
            }
        }
    }

    // MARK: - Consent Response

    func acceptConnection() {
        guard let request = pendingIncomingRequest else { return }
        pendingIncomingRequest = nil
        connectedPeer = request.peerIdentity
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
                transition(to: .failed(reason: error.localizedDescription))
            }
        }
    }

    func rejectConnection() {
        guard let request = pendingIncomingRequest else { return }
        pendingIncomingRequest = nil

        Task {
            let reject = PeerMessage.connectionReject(senderID: localIdentity.id)
            try? await request.connection.sendMessage(reject)
            request.connection.cancel()
            transition(to: .rejected)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            transition(to: .discovering)
        }
    }

    func disconnect() {
        cancelTimeouts()
        Task {
            if let connection = activeConnection {
                let msg = PeerMessage.disconnect(senderID: localIdentity.id)
                try? await connection.sendMessage(msg)
                connection.cancel()
            }
            activeConnection = nil
            connectedPeer = nil
            endBackgroundTask()
            transition(to: .disconnected)
        }
    }

    // MARK: - Message Receive Loop

    private func startReceiving() {
        guard let connection = activeConnection else {
            logger.warning("startReceiving: no activeConnection!")
            return
        }
        logger.info("Entering receive loop")

        Task {
            while activeConnection != nil {
                do {
                    let message = try await connection.receiveMessage()
                    handleMessage(message)
                } catch {
                    logger.error("Receive loop error: \(error.localizedDescription)")
                    if activeConnection != nil {
                        fileTransfer?.handleConnectionFailure()
                        transition(to: .failed(reason: error.localizedDescription))
                        activeConnection = nil
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

        case .disconnect:
            activeConnection?.cancel()
            activeConnection = nil
            connectedPeer = nil
            transition(to: .disconnected)

        case .fileOffer:
            fileTransfer?.handleFileOffer(message)

        case .fileAccept:
            fileTransfer?.handleFileAccept()

        case .fileReject:
            fileTransfer?.handleFileReject()

        case .fileChunk:
            fileTransfer?.handleFileChunk(message)

        case .fileComplete:
            fileTransfer?.handleFileComplete(message)

        case .callRequest:
            voiceCallManager?.handleCallRequest(from: message.senderID)

        case .callAccept:
            voiceCallManager?.handleCallAccept()

        case .callReject:
            voiceCallManager?.handleCallReject()

        case .callEnd:
            voiceCallManager?.handleCallEnd()

        case .sdpOffer, .sdpAnswer, .iceCandidate:
            voiceCallManager?.handleSignaling(message)

        case .textMessage:
            if let payload = try? message.decodePayload(TextMessagePayload.self) {
                chatManager.saveIncoming(
                    text: payload.text,
                    peerID: message.senderID,
                    peerName: connectedPeer?.displayName ?? "Unknown"
                )
            }

        case .mediaMessage:
            if let payload = try? message.decodePayload(MediaMessagePayload.self) {
                chatManager.saveIncomingMedia(
                    payload: payload,
                    fileData: Data(),
                    peerID: message.senderID,
                    peerName: connectedPeer?.displayName ?? "Unknown"
                )
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
        case .cancelled:
            cancelTimeouts()
            activeConnection = nil
        @unknown default:
            print("[ConnectionManager] Unknown network connection state")
        }
    }

    // MARK: - Chat

    func sendTextMessage(_ text: String) {
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
