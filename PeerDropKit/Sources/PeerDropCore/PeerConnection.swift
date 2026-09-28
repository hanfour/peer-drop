import Foundation
import PeerDropTransport
import PeerDropProtocol
import PeerDropSecurity
import Network
import Combine
import CryptoKit
import os

private let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "PeerConnection")

/// Encapsulates a single peer connection with its own state, identity, and sessions.
@MainActor
public final class PeerConnection: ObservableObject, Identifiable {
    public let id: String  // peerID
    private(set) var transport: TransportProtocol
    @Published public private(set) var peerIdentity: PeerIdentity
    @Published public private(set) var state: PeerConnectionState

    /// Independent file transfer session for this peer.
    var fileTransferSession: FileTransferSession?

    /// Independent voice call session for this peer.
    var voiceCallSession: VoiceCallSession?

    /// Tracks whether this connection is currently transferring a file.
    @Published public private(set) var isTransferring: Bool = false

    /// Tracks whether this connection is in a voice call.
    @Published public private(set) var isInVoiceCall: Bool = false

    /// When this connection entered the connected state.
    public private(set) var connectedSince: Date?

    /// Bytes transferred in the last measurement window (for speed calculation).
    @Published public private(set) var transferSpeed: Int64 = 0
    private var lastBytesCount: Int64 = 0
    private var speedTimer: Timer?

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

    /// Still carrying the `relay-<code>` placeholder identity (#161 I-1).
    /// Structural: set only by `ConnectionManager.installRelayPlaceholder`,
    /// consumed by the first per-peer HELLO, and cleared when the connection
    /// is removed or overwritten. Lives on the object (not as an
    /// ObjectIdentifier in a set), so it can never be inherited by a later
    /// object allocated at the same address.
    var isRelayPlaceholder = false

    // MARK: - Secure channel (audit-#13 Phase 2)

    /// Active local-TCP secure channel, or nil if the peer hasn't completed
    /// the Double Ratchet handshake. When set, `sendMessage` automatically
    /// encrypts non-control messages and the receive loop decrypts
    /// `.secureEnvelope` frames before delivering to `onMessageReceived`.
    private(set) var secureChannel: LocalSecureChannel?

    /// Ratchet private key generated when we sent OUR handshake bundle,
    /// kept until we receive the peer's bundle so we can complete
    /// `LocalSecureChannel.establish`. Cleared after establishment.
    private var pendingRatchetPrivateKey: Curve25519.KeyAgreement.PrivateKey?

    /// Phase of the local-TCP handshake.
    public enum SecureChannelState: Equatable {
        case disabled              // never initiated; sendMessage plaintext
        case handshakeInProgress   // our bundle sent, awaiting peer's bundle
        case secured               // both bundles exchanged, channel ready
        case fallbackPlaintext     // peer didn't respond in time; staying plaintext
    }
    @Published public private(set) var secureChannelState: SecureChannelState = .disabled {
        didSet { signalSendReadiness() }
    }

    /// Fingerprint-pinning verdict from the most recent handshake. Exposed
    /// for the UI so the connected-peers list can surface a lock icon for
    /// `.matched`/`.firstTrust` and a warning chip for `.mismatch`.
    public enum PinningVerdict: Equatable {
        case notChecked         // channel not yet secured
        case firstTrust         // peer was unknown to TrustedContactStore — TOFU stored
        case matched            // peer key matched the existing TrustedContact entry
        case mismatch(stored: String, received: String)  // ALERT — key changed silently
    }
    @Published public private(set) var pinningVerdict: PinningVerdict = .notChecked

    /// Update the pinning verdict from outside (called by ConnectionManager
    /// after running the TrustedContactStore lookup in the
    /// `onSecureChannelEstablished` callback). Keeps `pinningVerdict`'s
    /// setter `private(set)` so business code can't randomly flip it.
    public func setPinningVerdict(_ verdict: PinningVerdict) {
        pinningVerdict = verdict
    }

    /// Hook called when handshake completes so callers (`ConnectionManager`)
    /// can run pinning + UI side effects. Receives the peer's fingerprint
    /// (already on `secureChannel.peerFingerprint`).
    var onSecureChannelEstablished: ((String) -> Void)?

    /// Plaintext-fallback timer task. Cancelled when handshake completes.
    private var handshakeFallbackTask: Task<Void, Never>?

    /// How long to wait for a peer's handshake response before giving up
    /// and falling back to plaintext mode. Both ends of a v5.1+ pair
    /// should respond in well under 1 second; 5 seconds is conservative
    /// enough that a slow-launching peer can still complete.
    public static let handshakeFallbackSeconds: UInt64 = 5

    /// Fallback timer length (tests shorten it). Also bounds how long a
    /// business send is held waiting for the channel (see `sendMessage`).
    var handshakeFallbackNanoseconds: UInt64 = PeerConnection.handshakeFallbackSeconds * 1_000_000_000

    /// The ONLY message types that travel unwrapped once a secure channel
    /// exists — used by BOTH directions (#170), so they cannot drift apart:
    ///
    /// - send: `sendMessage` does not wrap these; `disconnect()` writes
    ///   `.disconnect` straight to the transport; the handshake writes
    ///   `.secureHandshake` (bundle / passive reply) straight to the transport.
    /// - receive: once `secureChannel != nil`, `handleIncomingMessage` drops
    ///   every plaintext frame whose type is not in this set.
    ///
    /// Derivation (every raw `transport.send` / NWConnection send that can
    /// follow our handshake bundle on the same socket):
    /// - `.secureHandshake` — chicken-and-egg; a duplicate on a live channel
    ///   is a logged no-op (`handleIncomingSecureHandshake`).
    /// - `.ping` / `.pong` — keepalive (PeerConnection heartbeat, and the
    ///   ConnectionManager pong reply); not worth ratchet steps.
    /// - `.disconnect` — `disconnect()` and ConnectionManager's legacy
    ///   `activeConnection` teardown write it raw, and peers built before
    ///   #170 always send it raw. Dropping it would leave zombie
    ///   connections; an on-path attacker able to inject it can already tear
    ///   the TCP stream down with a RST, so accepting it grants nothing new.
    /// Everything else ConnectionManager sends raw (`hello`,
    /// `connectionRequest/Accept/Reject`, pre-consent pong) goes out before the
    /// PeerConnection exists, i.e. before either handshake bundle.
    static let unwrappedControlTypes: Set<MessageType> = [
        .secureHandshake,
        .ping, .pong,
        .disconnect,
    ]

    /// Ratchet responders have no sending chain until the first inbound
    /// envelope; tracked so business sends can wait for it (#170).
    private var hasReceivedEnvelope = false {
        didSet { signalSendReadiness() }
    }

    /// Business sends parked until the channel can carry them (#170).
    private var sendReadinessWaiters: [CheckedContinuation<Void, Never>] = []

    /// Backward-compatible accessor for the underlying NWConnection (TCP transport only).
    var nwConnection: NWConnection? {
        (transport as? TCPTransport)?.connection
    }

    /// Backward-compatible accessor (alias for `nwConnection`).
    /// Returns nil for non-TCP transports (e.g. DataChannelTransport).
    var connection: NWConnection? { nwConnection }

    init(
        peerID: String,
        transport: TransportProtocol,
        peerIdentity: PeerIdentity,
        localIdentity: PeerIdentity,
        state: PeerConnectionState = .connecting
    ) {
        self.id = peerID
        self.transport = transport
        self.peerIdentity = peerIdentity
        self.localIdentity = localIdentity
        self.state = state
    }

    /// Convenience initializer for backward compatibility with NWConnection.
    convenience init(
        peerID: String,
        connection: NWConnection,
        peerIdentity: PeerIdentity,
        localIdentity: PeerIdentity,
        state: PeerConnectionState = .connecting
    ) {
        let tcpTransport = TCPTransport(connection: connection)
        self.init(
            peerID: peerID,
            transport: tcpTransport,
            peerIdentity: peerIdentity,
            localIdentity: localIdentity,
            state: state
        )
    }

    deinit {
        heartbeatTask?.cancel()
        speedTimer?.invalidate()
    }

    // MARK: - State Management

    public func updateState(_ newState: PeerConnectionState) {
        guard state != newState else { return }
        logger.info("PeerConnection[\(self.id.prefix(8))] state: \(String(describing: self.state)) → \(String(describing: newState))")
        state = newState
        signalSendReadiness()
        onStateChange?(newState)

        switch newState {
        case .connected:
            connectedSince = Date()
            startHeartbeat()
        case .disconnected, .failed:
            connectedSince = nil
            stopHeartbeat()
            onDisconnected?()
        case .connecting:
            break
        }
    }

    public func updatePeerIdentity(_ identity: PeerIdentity) {
        peerIdentity = identity
    }

    public func replaceTransport(_ newTransport: TransportProtocol) {
        transport = newTransport
        connectionGeneration = UUID()
    }

    /// Backward-compatible method for replacing the underlying NWConnection.
    public func replaceConnection(_ newConnection: NWConnection) {
        replaceTransport(TCPTransport(connection: newConnection))
    }

    // MARK: - Transfer State

    public func setTransferring(_ transferring: Bool) {
        isTransferring = transferring
        if transferring {
            startSpeedTracking()
        } else {
            stopSpeedTracking()
        }
    }

    public func recordBytesTransferred(_ bytes: Int64) {
        lastBytesCount += bytes
    }

    private func startSpeedTracking() {
        lastBytesCount = 0
        transferSpeed = 0
        speedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.transferSpeed = self.lastBytesCount
                self.lastBytesCount = 0
            }
        }
    }

    private func stopSpeedTracking() {
        speedTimer?.invalidate()
        speedTimer = nil
        transferSpeed = 0
        lastBytesCount = 0
    }

    public func setInVoiceCall(_ inCall: Bool) {
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

    public func sendMessage(_ message: PeerMessage) async throws {
        guard state.isActive else {
            throw ConnectionError.notConnected
        }
        let isControl = Self.unwrappedControlTypes.contains(message.type)
        if !isControl {
            // #170: once our handshake bundle is on the wire the peer drops
            // plaintext business frames, so hold them until the channel can
            // encrypt (or the handshake falls back to plaintext).
            await waitUntilBusinessSendable()
            guard state.isActive else {
                throw ConnectionError.notConnected
            }
        }
        // If we have a secured channel and this message isn't an unwrapped
        // control type, wrap it before hitting the wire. Wrapping fails
        // closed — if encrypt throws, the message does NOT fall through to
        // plaintext.
        if let channel = secureChannel, !isControl {
            let plaintext = try message.encoded()
            let frame = try channel.encrypt(plaintext)
            let envelope = PeerMessage.secureEnvelope(frame: frame, senderID: localIdentity.id)
            try await transport.send(envelope)
            return
        }
        try await transport.send(message)
    }

    /// Whether a business (non-control) send must wait right now (#170):
    /// - `.handshakeInProgress`: our bundle is on the wire; the peer is (or
    ///   will be, by the time it reads this frame) secured and would drop a
    ///   plaintext business frame.
    /// - `.secured` as ratchet responder before the first inbound envelope:
    ///   `encrypt` would throw `noSendChain`. The initiator sends a no-op
    ///   envelope right after establishing (ConnectionManager bootstrap).
    private var mustHoldBusinessSend: Bool {
        guard state.isActive else { return false }
        switch secureChannelState {
        case .handshakeInProgress:
            return true
        case .secured:
            return secureChannel?.isInitiator == false && !hasReceivedEnvelope
        case .disabled, .fallbackPlaintext:
            return false
        }
    }

    private final class HoldTimeout { var fired = false }

    /// Wait until `mustHoldBusinessSend` clears, bounded by
    /// `handshakeFallbackNanoseconds` (after which the send proceeds and
    /// behaves as it did before #170).
    private func waitUntilBusinessSendable() async {
        guard mustHoldBusinessSend else { return }
        let timeout = HoldTimeout()
        let limit = handshakeFallbackNanoseconds
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: limit)
            timeout.fired = true
            self?.signalSendReadiness()
        }
        defer { timer.cancel() }
        while mustHoldBusinessSend && !timeout.fired {
            await withCheckedContinuation { sendReadinessWaiters.append($0) }
        }
    }

    private func signalSendReadiness() {
        guard !sendReadinessWaiters.isEmpty else { return }
        let waiters = sendReadinessWaiters
        sendReadinessWaiters = []
        waiters.forEach { $0.resume() }
    }

    // MARK: - Secure Channel (audit-#13 Phase 2)

    /// Initiate the local-TCP secure handshake. Generates a fresh
    /// ephemeral ratchet key, sends our `HandshakeBundle` over the wire
    /// in plaintext, and transitions to `.handshakeInProgress`. The
    /// channel becomes `.secured` once `handleIncomingSecureHandshake`
    /// fires on the peer's response.
    ///
    /// Idempotent: calling twice on the same connection is a no-op the
    /// second time. Caller should `await` this before sending business
    /// messages — calls to `sendMessage` between initiation and
    /// completion go through the plaintext path.
    ///
    /// `identity` defaults to the device singleton; tests inject a fake.
    public func initiateSecureHandshake(identity: LocalChannelIdentity = IdentityKeyManager.shared) async throws {
        guard secureChannelState == .disabled else { return }
        let (bundle, ratchetPriv) = LocalSecureChannel.prepareHandshake(identity: identity)
        pendingRatchetPrivateKey = ratchetPriv
        secureChannelState = .handshakeInProgress
        scheduleHandshakeFallback()
        let message = try PeerMessage.secureHandshake(bundle: bundle, senderID: localIdentity.id)
        try await transport.send(message)
    }

    /// ConnectionManager's entry point: called after the hello exchange
    /// confirms the peer's capability flag. Initiates the handshake when
    /// both peers support it; otherwise leaves the channel disabled so
    /// every PeerMessage stays on the plaintext path (v5.0.x compat).
    public func startSecureChannelNegotiation(
        peerSupportsSecureChannel: Bool,
        identity: LocalChannelIdentity = IdentityKeyManager.shared
    ) async {
        guard peerSupportsSecureChannel else {
            logger.info("PeerConnection[\(self.id.prefix(8))] peer doesn't support secure channel — staying plaintext")
            return
        }
        do {
            try await initiateSecureHandshake(identity: identity)
        } catch {
            logger.error("PeerConnection[\(self.id.prefix(8))] secure handshake send failed: \(error.localizedDescription); falling back to plaintext")
            secureChannelState = .fallbackPlaintext
        }
    }

    /// Schedule the plaintext-fallback timer. If we're still in
    /// `.handshakeInProgress` after N seconds, give up on the peer and
    /// move to `.fallbackPlaintext`. Without this, a buggy peer that
    /// promised support but never sends the response bundle would leave
    /// us stuck waiting forever and silently dropping every business
    /// message (sendMessage looks at `secureChannel`, which stays nil
    /// until establish() runs).
    private func scheduleHandshakeFallback() {
        handshakeFallbackTask?.cancel()
        let generation = connectionGeneration
        let delay = handshakeFallbackNanoseconds
        handshakeFallbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled, self.connectionGeneration == generation else { return }
            if self.secureChannelState == .handshakeInProgress {
                logger.warning("PeerConnection[\(self.id.prefix(8))] handshake fallback fired after \(delay / 1_000_000)ms — peer didn't respond")
                self.secureChannelState = .fallbackPlaintext
                self.pendingRatchetPrivateKey = nil
            }
        }
    }

    /// Process an inbound `.secureHandshake` message. If we haven't yet
    /// sent our own bundle, send it now (passive responder case). Then
    /// derive the channel from our held ratchet private key + the peer's
    /// bundle. After success, `secureChannel` is non-nil and state is
    /// `.secured`.
    public func handleIncomingSecureHandshake(
        _ message: PeerMessage,
        identity: LocalChannelIdentity = IdentityKeyManager.shared
    ) async throws {
        guard message.type == .secureHandshake else {
            throw SecureChannelError.unexpectedMessageType
        }
        // Drop duplicate handshakes once the channel is up. Without this,
        // a replayed-or-stuck bundle would generate a new ratchet key,
        // call `establish` again, and replace the working channel with a
        // fresh one — destroying in-flight session state and breaking
        // every subsequent decrypt.
        guard secureChannelState != .secured else {
            logger.warning("PeerConnection[\(self.id.prefix(8))] ignoring duplicate handshake on secured channel")
            return
        }
        let bundle = try message.decodePayload(LocalSecureChannel.HandshakeBundle.self)

        // Passive responder: peer initiated; we never called
        // initiateSecureHandshake. Generate our bundle on demand + send it
        // so the peer can complete its own establish() on the other side.
        if pendingRatchetPrivateKey == nil {
            let (ourBundle, ratchetPriv) = LocalSecureChannel.prepareHandshake(identity: identity)
            pendingRatchetPrivateKey = ratchetPriv
            secureChannelState = .handshakeInProgress
            scheduleHandshakeFallback()
            let reply = try PeerMessage.secureHandshake(bundle: ourBundle, senderID: localIdentity.id)
            try await transport.send(reply)
        }

        guard let ratchetPriv = pendingRatchetPrivateKey else {
            throw SecureChannelError.missingPendingKey
        }
        secureChannel = try LocalSecureChannel.establish(
            myIdentity: identity,
            myRatchetPrivateKey: ratchetPriv,
            peerBundle: bundle
        )
        pendingRatchetPrivateKey = nil
        secureChannelState = .secured
        handshakeFallbackTask?.cancel()
        handshakeFallbackTask = nil
        let fingerprint = secureChannel?.peerFingerprint ?? "?"
        logger.info("PeerConnection[\(self.id.prefix(8))] secure channel established; peer fingerprint=\(fingerprint, privacy: .public)")
        onSecureChannelEstablished?(fingerprint)
    }

    /// Errors specific to the secure-channel handshake.
    enum SecureChannelError: Error, Equatable {
        case unexpectedMessageType
        case missingPendingKey
        case envelopeWithoutChannel  // received .secureEnvelope before establishing
    }

    // MARK: - Receive Loop

    public func startReceiving() {
        let generation = connectionGeneration
        logger.info("PeerConnection[\(self.id.prefix(8))] starting receive loop")

        Task {
            while connectionGeneration == generation && state.isActive {
                do {
                    let message = try await transport.receive()
                    guard connectionGeneration == generation else { break }
                    try await handleIncomingMessage(message)
                } catch {
                    logger.error("PeerConnection[\(self.id.prefix(8))] receive error: \(error.localizedDescription)")
                    guard connectionGeneration == generation else { break }
                    updateState(.failed(reason: error.localizedDescription))
                    break
                }
            }
        }
    }

    /// Dispatch one incoming wire message. Handshake + envelope frames are
    /// handled internally; business messages are forwarded to
    /// `onMessageReceived`. Pulled out of `startReceiving` so the secure
    /// channel logic stays testable and the receive loop stays small.
    public func handleIncomingMessage(_ message: PeerMessage) async throws {
        switch message.type {
        case .secureHandshake:
            try await handleIncomingSecureHandshake(message)

        case .secureEnvelope:
            guard let channel = secureChannel else {
                // Envelope arrived before handshake completed. Drop it
                // (logging) rather than throwing — a misbehaving peer
                // shouldn't be able to kill our receive loop.
                logger.error("PeerConnection[\(self.id.prefix(8))] dropped .secureEnvelope before channel established")
                return
            }
            guard let frame = message.payload else { return }
            let plaintext = try channel.decrypt(frame)
            if !hasReceivedEnvelope { hasReceivedEnvelope = true }
            let inner = try PeerMessage.decoded(from: plaintext)
            onMessageReceived?(inner)

        default:
            // #170: once the channel is established every honest business
            // frame arrives as an envelope (the sender held it until secured —
            // see `sendMessage`). A plaintext one is an injection (TLS accepts
            // any cert, #167) or a pre-#170 peer's handshake-window race: drop
            // it, keep the connection (tearing down would hand an injector a
            // kill switch it already has via RST, and would cut off older
            // honest peers). Log the type only — never the payload.
            if secureChannel != nil, !Self.unwrappedControlTypes.contains(message.type) {
                logger.warning("PeerConnection[\(self.id.prefix(8))] dropped plaintext \(message.type.rawValue, privacy: .public) on secured channel")
                return
            }
            onMessageReceived?(message)
        }
    }

    // MARK: - Disconnect

    public func disconnect(sendMessage: Bool = true) async {
        logger.info("PeerConnection[\(self.id.prefix(8))] disconnecting")
        connectionGeneration = UUID()
        heartbeatTask?.cancel()
        heartbeatTask = nil

        if sendMessage {
            // Unwrapped on purpose — `.disconnect` is in `unwrappedControlTypes`.
            let msg = PeerMessage.disconnect(senderID: localIdentity.id)
            try? await transport.send(msg)
        }

        transport.close()
        updateState(.disconnected)
    }

    public func cancel() {
        connectionGeneration = UUID()
        transport.close()
    }
}
