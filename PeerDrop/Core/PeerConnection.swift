import Foundation
import Network
import Combine
import os

private let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "PeerConnection")

/// Encapsulates a single peer connection with its own state, identity, and sessions.
@MainActor
final class PeerConnection: ObservableObject, Identifiable {
    let id: String  // peerID
    private(set) var connection: NWConnection
    @Published private(set) var peerIdentity: PeerIdentity
    @Published private(set) var state: PeerConnectionState

    /// Independent file transfer session for this peer.
    var fileTransferSession: FileTransferSession?

    /// Independent voice call session for this peer.
    var voiceCallSession: VoiceCallSession?

    /// Tracks whether this connection is currently transferring a file.
    @Published private(set) var isTransferring: Bool = false

    /// Tracks whether this connection is in a voice call.
    @Published private(set) var isInVoiceCall: Bool = false

    /// Callback when the connection state changes.
    var onStateChange: ((PeerConnectionState) -> Void)?

    /// Callback when a message is received.
    var onMessageReceived: ((PeerMessage) -> Void)?

    /// Callback when the connection should be removed.
    var onDisconnected: (() -> Void)?

    /// Tracks the connection generation to ignore stale callbacks.
    private var connectionGeneration: UUID = UUID()

    /// Heartbeat task for keepalive.
    private var heartbeatTask: Task<Void, Never>?

    /// Local identity for sending messages.
    private let localIdentity: PeerIdentity

    init(
        peerID: String,
        connection: NWConnection,
        peerIdentity: PeerIdentity,
        localIdentity: PeerIdentity,
        state: PeerConnectionState = .connecting
    ) {
        self.id = peerID
        self.connection = connection
        self.peerIdentity = peerIdentity
        self.localIdentity = localIdentity
        self.state = state
    }

    deinit {
        heartbeatTask?.cancel()
    }

    // MARK: - State Management

    func updateState(_ newState: PeerConnectionState) {
        guard state != newState else { return }
        logger.info("PeerConnection[\(self.id.prefix(8))] state: \(String(describing: self.state)) → \(String(describing: newState))")
        state = newState
        onStateChange?(newState)

        switch newState {
        case .connected:
            startHeartbeat()
        case .disconnected, .failed:
            stopHeartbeat()
            onDisconnected?()
        case .connecting:
            break
        }
    }

    func updatePeerIdentity(_ identity: PeerIdentity) {
        peerIdentity = identity
    }

    func replaceConnection(_ newConnection: NWConnection) {
        connection = newConnection
        connectionGeneration = UUID()
    }

    // MARK: - Transfer State

    func setTransferring(_ transferring: Bool) {
        isTransferring = transferring
    }

    func setInVoiceCall(_ inCall: Bool) {
        isInVoiceCall = inCall
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        let generation = connectionGeneration
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
                    guard let self, !Task.isCancelled, self.connectionGeneration == generation else { return }
                    guard self.state.isConnected, !self.isTransferring else { continue }
                    let ping = PeerMessage.ping(senderID: self.localIdentity.id)
                    try? await self.sendMessage(ping)
                } catch {
                    return
                }
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    // MARK: - Message Sending

    func sendMessage(_ message: PeerMessage) async throws {
        guard state.isActive else {
            throw ConnectionError.notConnected
        }
        try await connection.sendMessage(message)
    }

    // MARK: - Receive Loop

    func startReceiving() {
        let generation = connectionGeneration
        logger.info("PeerConnection[\(self.id.prefix(8))] starting receive loop")

        Task {
            while connectionGeneration == generation && state.isActive {
                do {
                    let message = try await connection.receiveMessage()
                    guard connectionGeneration == generation else { break }
                    onMessageReceived?(message)
                } catch {
                    logger.error("PeerConnection[\(self.id.prefix(8))] receive error: \(error.localizedDescription)")
                    guard connectionGeneration == generation else { break }
                    updateState(.failed(reason: error.localizedDescription))
                    break
                }
            }
        }
    }

    // MARK: - Disconnect

    func disconnect(sendMessage: Bool = true) async {
        logger.info("PeerConnection[\(self.id.prefix(8))] disconnecting")
        connectionGeneration = UUID()

        if sendMessage {
            let msg = PeerMessage.disconnect(senderID: localIdentity.id)
            try? await connection.sendMessage(msg)
        }

        connection.cancel()
        updateState(.disconnected)
    }

    func cancel() {
        connectionGeneration = UUID()
        connection.cancel()
    }
}
