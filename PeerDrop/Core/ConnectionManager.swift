import Foundation
import Network
import Combine
import SwiftUI
import UIKit

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

    // MARK: - State Transitions

    func transition(to newState: ConnectionState) {
        let target = TransitionTarget(from: newState)
        guard state.canTransition(to: target) else {
            print("[ConnectionManager] Invalid transition: \(state) → \(newState)")
            return
        }
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
        transition(to: .requesting)

        let endpoint: NWEndpoint
        switch peer.endpoint {
        case .bonjour(let name, let type, let domain):
            endpoint = .service(name: name, type: type, domain: domain, interface: nil)
        case .manual(let host, let port):
            endpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        }

        // Use TLS for outgoing connections (trust-on-first-use)
        let clientTLS = TLSConfiguration.clientOptions(
            identity: certificateManager.identity
        )
        let params = NWParameters.peerDrop(tls: clientTLS)
        let connection = NWConnection(to: endpoint, using: params)

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleConnectionStateChange(state)
            }
        }

        connection.start(queue: .global(qos: .userInitiated))
        activeConnection = connection

        startRequestingTimeout()

        Task {
            do {
                try await connection.waitReady()
                let hello = try PeerMessage.hello(identity: localIdentity)
                try await connection.sendMessage(hello)
                let request = PeerMessage.connectionRequest(senderID: localIdentity.id)
                try await connection.sendMessage(request)
                startReceiving()
            } catch {
                cancelTimeouts()
                transition(to: .failed(reason: error.localizedDescription))
            }
        }
    }

    // MARK: - Incoming Connection

    private func handleIncomingConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        activeConnection = connection

        Task {
            do {
                try await connection.waitReady()
                let helloMsg = try await connection.receiveMessage()

                guard helloMsg.type == .hello, let payload = helloMsg.payload else {
                    connection.cancel()
                    return
                }

                let peerIdentity = try JSONDecoder().decode(PeerIdentity.self, from: payload)
                let requestMsg = try await connection.receiveMessage()

                guard requestMsg.type == .connectionRequest else {
                    connection.cancel()
                    return
                }

                transition(to: .incomingRequest)
                pendingIncomingRequest = IncomingRequest(
                    peerIdentity: peerIdentity,
                    connection: connection
                )
            } catch {
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
        guard let connection = activeConnection else { return }

        Task {
            while activeConnection != nil {
                do {
                    let message = try await connection.receiveMessage()
                    handleMessage(message)
                } catch {
                    if activeConnection != nil {
                        transition(to: .failed(reason: error.localizedDescription))
                        activeConnection = nil
                    }
                    break
                }
            }
        }
    }

    private func handleMessage(_ message: PeerMessage) {
        switch message.type {
        case .connectionAccept:
            cancelTimeouts()
            if let payload = message.payload,
               let identity = try? JSONDecoder().decode(PeerIdentity.self, from: payload) {
                connectedPeer = identity
            }
            transition(to: .connected)

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

        case .hello:
            // Already handled during handshake
            break
        case .connectionRequest:
            // Already handled during handshake
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
            activeConnection = nil
            transition(to: .failed(reason: error.localizedDescription))
        case .cancelled:
            cancelTimeouts()
            activeConnection = nil
        @unknown default:
            print("[ConnectionManager] Unknown network connection state")
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
