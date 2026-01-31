import Foundation
import Network
import Combine
import SwiftUI

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

    // MARK: - Internal

    private var discoveryCoordinator: DiscoveryCoordinator?
    private var bonjourDiscovery: BonjourDiscovery?
    private var activeConnection: NWConnection?
    private var cancellables = Set<AnyCancellable>()
    private let localIdentity: PeerIdentity
    private let certificateManager = CertificateManager()

    // MARK: - Submanagers (set after init)

    var fileTransfer: FileTransfer?
    var voiceCallManager: VoiceCallManager?

    init() {
        let certManager = CertificateManager()
        self.localIdentity = .local(certificateFingerprint: certManager.fingerprint)
    }

    // MARK: - State Transitions

    func transition(to newState: ConnectionState) {
        let target = TransitionTarget(from: newState)
        guard state.canTransition(to: target) else {
            print("[ConnectionManager] Invalid transition: \(state) → \(newState)")
            return
        }
        state = newState
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

    // MARK: - Connection Request (Outgoing)

    func requestConnection(to peer: DiscoveredPeer) {
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

        Task {
            do {
                try await connection.waitReady()
                let hello = try PeerMessage.hello(identity: localIdentity)
                try await connection.sendMessage(hello)
                let request = PeerMessage.connectionRequest(senderID: localIdentity.id)
                try await connection.sendMessage(request)
                startReceiving()
            } catch {
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

        Task {
            do {
                let accept = PeerMessage.connectionAccept(senderID: localIdentity.id)
                try await request.connection.sendMessage(accept)
                let hello = try PeerMessage.hello(identity: localIdentity)
                try await request.connection.sendMessage(hello)
                transition(to: .connected)
                startReceiving()
            } catch {
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
        Task {
            if let connection = activeConnection {
                let msg = PeerMessage.disconnect(senderID: localIdentity.id)
                try? await connection.sendMessage(msg)
                connection.cancel()
            }
            activeConnection = nil
            connectedPeer = nil
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
            if let payload = message.payload,
               let identity = try? JSONDecoder().decode(PeerIdentity.self, from: payload) {
                connectedPeer = identity
            }
            transition(to: .connected)

        case .connectionReject:
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
        case .failed(let error):
            activeConnection = nil
            transition(to: .failed(reason: error.localizedDescription))
        case .cancelled:
            activeConnection = nil
        default:
            break
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
