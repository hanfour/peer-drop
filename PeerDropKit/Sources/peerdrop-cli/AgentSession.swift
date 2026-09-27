import Foundation
import PeerDropCore
import PeerDropSecurity
import PeerDropProtocol
import Combine

/// Owns the policy for accepting, enrolling, or rejecting inbound peer
/// identities, and routes messages between the ProcessBridge and attached peers.
///
/// ## Concurrency model
/// `decideTrust` is a pure `nonisolated static` — the unit tests call it
/// synchronously off the main actor.
///
/// All mutable state (`attachedPeerIDs`, `scrollback`, pending replays, the
/// send chain) is confined to the main actor:
/// - the `onTextMessageReceived` hook runs on the main actor, and
/// - the ProcessBridge's background-queue `broadcast` hops to the main queue.
/// Outbound sends are serialised through one chain and re-check the input
/// gate before each line (#166).
final class AgentSession {

    // MARK: - Trust Decision

    enum TrustDecision: Equatable {
        case autoAccept
        case enroll
        case reject
    }

    /// Pure trust decision used by the connection-accept path and unit tests.
    /// `nonisolated` so the test can call it without `await`.
    ///
    /// Policy: only `.verified` or `.linked` contacts auto-accept.
    /// A contact that exists but has `trustLevel == .unknown` still requires
    /// enrollment — the peer has not yet been paired/verified.
    nonisolated static func decideTrust(
        identityKey: Data,
        store: TrustedContactStore
    ) -> TrustDecision {
        guard let contact = store.find(byPublicKey: identityKey) else { return .enroll }
        if contact.isBlocked { return .reject }
        return contact.trustLevel == .unknown ? .enroll : .autoAccept
    }

    // MARK: - Connection-Accept Action

    /// What the CLI does with an inbound connection request.
    /// - `acceptTrusted`: known, verified contact. Input still has to pass
    ///   `InputGate` (secured channel, handshake key == hello key, `.matched`).
    /// - `acceptPendingSAS`: unknown peer. The connection is accepted ONLY so the
    ///   secure handshake can run and the SAS prompt can appear; the peer is not
    ///   trusted and its input is dropped until the user answers "y".
    /// - `reject`: blocked, or a peer that cannot do the secure channel (it could
    ///   never be authenticated, so there is no point keeping it connected).
    enum ConnectionAction: Equatable {
        case acceptTrusted
        case acceptPendingSAS
        case reject
    }

    nonisolated static func connectionAction(
        for decision: TrustDecision,
        peerSupportsSecureChannel: Bool
    ) -> ConnectionAction {
        guard peerSupportsSecureChannel else { return .reject }
        switch decision {
        case .reject: return .reject
        case .enroll: return .acceptPendingSAS
        case .autoAccept: return .acceptTrusted
        }
    }

    /// Peers that may receive process output: attached (they sent authorised
    /// input this session) AND still passing the gate right now — so a later
    /// connection that re-uses an attached peer's ID but fails the gate gets
    /// nothing.
    nonisolated static func outputRecipients(
        attached: Set<String>,
        isAuthorized: (String) -> Bool
    ) -> Set<String> {
        attached.filter(isAuthorized)
    }

    // MARK: - Properties

    private let bridge: MessageBridge
    private let cm: ConnectionManager
    private let store: TrustedContactStore

    /// Input/output authorisation for a hook peerID. Defaults to `InputGate`
    /// over the live ConnectionManager; injectable for tests. Main-actor only.
    private let isAuthorized: (String) -> Bool
    /// Sends one line of process output to a peer. Main-actor isolated so that
    /// calling it from the (main-actor) send queue does not hop: the gate check
    /// and the connection the line goes out on stay in one main-actor turn.
    /// The default re-resolves the peer through `InputGate.approvedConnection`
    /// and sends on that exact PeerConnection object.
    private let sendToPeer: @MainActor (String, String) async -> Void
    /// Emits whenever something that feeds the gate changes for a peer's
    /// connection (secure-channel state, pinning verdict). Defaults to the live
    /// PeerConnection's publishers; nil if there is no connection.
    private let authorizationChanges: (String) -> AnyPublisher<Void, Never>?

    /// Watches for a reconnecting peer's connection becoming authorised.
    /// Confined to the main actor.
    private var replayWatchers: [String: AnyCancellable] = [:]

    /// Tail of the serial outbound-send chain: every send to every peer is
    /// appended here, so lines leave in the order they were enqueued on the
    /// main actor. Confined to the main actor.
    private var sendTail: Task<Void, Never>?

    /// Peers whose messages have been received in this session.
    /// Confined to the main actor.
    private(set) var attachedPeerIDs = Set<String>()

    /// Known peers that reconnected; their scrollback replay is deferred until
    /// the new connection passes the gate (it is never secured yet at connect
    /// time). Confined to the main actor.
    private var pendingReplayPeerIDs = Set<String>()

    /// Bounded scrollback of outgoing (bridge→peers) messages.
    /// Confined to the main actor.
    private var scrollback: [String] = []

    private static let scrollbackCap = 200

    // MARK: - Init

    init(
        bridge: MessageBridge,
        connectionManager: ConnectionManager,
        store: TrustedContactStore,
        isAuthorized: ((String) -> Bool)? = nil,
        sendToPeer: (@MainActor (String, String) async -> Void)? = nil,
        authorizationChanges: ((String) -> AnyPublisher<Void, Never>?)? = nil
    ) {
        self.sendToPeer = sendToPeer ?? { @MainActor [weak connectionManager] text, peerID in
            // Gate + resolve + build the message synchronously; the only
            // suspension is the transport send on the approved object.
            guard let cm = connectionManager,
                  let conn = InputGate.approvedConnection(for: peerID, cm: cm, store: store),
                  let message = try? PeerMessage.textMessage(
                      TextMessagePayload(text: text,
                                         senderName: cm.localIdentity.displayName,
                                         messageID: UUID().uuidString),
                      senderID: cm.localIdentity.id)
            else { return }
            try? await conn.sendMessage(message)
        }
        self.bridge = bridge
        self.cm = connectionManager
        self.store = store
        self.authorizationChanges = authorizationChanges ?? { [weak connectionManager] peerID in
            MainActor.assumeIsolated {
                guard let conn = connectionManager?.connection(for: peerID) else { return nil }
                return Publishers.Merge(
                    conn.$secureChannelState.map { _ in () },
                    conn.$pinningVerdict.map { _ in () }
                ).eraseToAnyPublisher()
            }
        }
        if let isAuthorized {
            self.isAuthorized = isAuthorized
        } else {
            self.isAuthorized = { [weak connectionManager] peerID in
                guard let cm = connectionManager else { return false }
                return MainActor.assumeIsolated {
                    InputGate.shouldForwardInput(InputGate.facts(for: peerID, cm: cm, store: store))
                }
            }
        }
    }

    // MARK: - Reconnect Detection

    /// A peer that has already interacted (is in `known`) and is connecting again
    /// is a RECONNECT → replay scrollback so it catches up. A brand-new peer
    /// (not in `known`) gets nothing dumped on it.
    nonisolated static func shouldReplayOnConnect(peerID: String, known: Set<String>) -> Bool {
        known.contains(peerID)
    }

    /// Call when a peer (re)connects. A reconnecting peer (one that sent
    /// authorised input earlier) gets the scrollback replayed — but only once
    /// its NEW connection passes the gate. At connect time the channel is never
    /// secured yet, so we watch the connection's state and flush when it
    /// becomes authorised (or on its next authorised input/output). Fail
    /// closed: no authorisation, no replay. Must run on the main actor.
    @MainActor
    func handlePeerConnected(_ peerID: String) {
        guard Self.shouldReplayOnConnect(peerID: peerID, known: attachedPeerIDs) else { return }
        pendingReplayPeerIDs.insert(peerID)
        // @Published emits in willSet, so hop to the next main-queue turn to
        // evaluate the gate against the updated values.
        replayWatchers[peerID] = authorizationChanges(peerID)?
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                MainActor.assumeIsolated { self?.flushPendingReplayIfAuthorized(peerID) }
            }
        flushPendingReplayIfAuthorized(peerID)
    }

    // MARK: - Wiring

    /// Installs the `onTextMessageReceived` hook on the ConnectionManager.
    /// Must be called from the main actor (ConnectionManager is main-actor bound).
    ///
    /// Security (#166): text is written into the wrapped process ONLY when the
    /// sender's connection passes `InputGate`. Everything else is dropped — not
    /// buffered — and logged without its content.
    @MainActor
    func wire() {
        cm.onTextMessageReceived = { [weak self] peerID, text in
            // ConnectionManager fires this hook from its main-actor handleMessage.
            MainActor.assumeIsolated {
                self?.handleInboundText(peerID: peerID, text: text)
            }
        }
    }

    @MainActor
    private func handleInboundText(peerID: String, text: String) {
        guard isAuthorized(peerID) else {
            print("dropped \(text.utf8.count)-byte input from unauthenticated peer \(TerminalSanitizer.sanitize(String(peerID.prefix(8))))")
            return
        }
        attachedPeerIDs.insert(peerID)
        flushPendingReplayIfAuthorized(peerID)
        // bridge.send is thread-safe (internal writeQueue).
        bridge.send(text)
    }

    /// Replays the scrollback to a reconnected peer once it is authorised.
    /// The snapshot is taken here, synchronously on the main actor, and joins
    /// the serial send chain, so lines are neither duplicated nor reordered
    /// relative to later output.
    @MainActor
    private func flushPendingReplayIfAuthorized(_ peerID: String) {
        guard pendingReplayPeerIDs.contains(peerID), isAuthorized(peerID) else { return }
        pendingReplayPeerIDs.remove(peerID)
        replayWatchers[peerID] = nil
        replayScrollback(to: peerID)
    }

    // MARK: - Broadcast

    /// Called by the ProcessBridge `onMessage` closure (runs on a background
    /// queue). `DispatchQueue.main.async` is FIFO, so output keeps its order.
    func broadcast(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.broadcastNow(text) }
        }
    }

    /// Appends `text` to the scrollback and sends it to every attached peer
    /// that currently passes the gate.
    @MainActor
    func broadcastNow(_ text: String) {
        appendScrollback(text)
        for peerID in Self.outputRecipients(attached: attachedPeerIDs, isAuthorized: isAuthorized) {
            if pendingReplayPeerIDs.contains(peerID) {
                // Reconnected peer just became authorised: its replay snapshot
                // already includes `text`.
                flushPendingReplayIfAuthorized(peerID)
            } else {
                enqueueSend([text], to: peerID)
            }
        }
    }

    /// Replays a snapshot of the bounded scrollback to `peerID`.
    @MainActor
    func replayScrollback(to peerID: String) {
        enqueueSend(scrollback, to: peerID)
    }

    /// Waits until every send enqueued so far has finished (tests).
    @MainActor
    func drainSends() async {
        await sendTail?.value
    }

    /// Appends `lines` for `peerID` to the serial send chain. Before EACH line
    /// the gate is re-checked and `sendToPeer` is entered in the same
    /// main-actor turn (both are main-actor isolated, so there is no hop in
    /// between); the default sender resolves and sends on the approved
    /// PeerConnection object itself. Nothing therefore goes to a new,
    /// unauthenticated connection that re-used the peer's ID mid-stream.
    @MainActor
    private func enqueueSend(_ lines: [String], to peerID: String) {
        guard !lines.isEmpty else { return }
        let previous = sendTail
        sendTail = Task { @MainActor [weak self] in
            await previous?.value
            for line in lines {
                guard let self, self.isAuthorized(peerID) else { return }
                await self.sendToPeer(line, peerID)
            }
        }
    }

    // MARK: - Private Helpers

    /// Appends `text` to the scrollback and trims to `scrollbackCap`.
    /// Must only be called from the main actor.
    @MainActor
    private func appendScrollback(_ text: String) {
        scrollback.append(text)
        if scrollback.count > Self.scrollbackCap {
            scrollback.removeFirst(scrollback.count - Self.scrollbackCap)
        }
    }
}
