import Foundation
import PeerDropCore
import PeerDropSecurity

/// Owns the policy for accepting, enrolling, or rejecting inbound peer
/// identities, and routes messages between the ProcessBridge and attached peers.
///
/// ## Concurrency model
/// `decideTrust` is a pure `nonisolated static` — the unit tests call it
/// synchronously off the main actor.
///
/// All mutable state (`attachedPeerIDs`, `scrollback`) is confined to the
/// main actor via `@MainActor Task` blocks, eliminating data races between:
/// - the main-actor `onTextMessageReceived` write path, and
/// - the ProcessBridge segmenter background-queue `broadcast` call path.
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
        isAuthorized: ((String) -> Bool)? = nil
    ) {
        self.bridge = bridge
        self.cm = connectionManager
        self.store = store
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

    /// Call when a peer (re)connects. Marks reconnecting peers for a scrollback
    /// replay, which happens once the connection is authorised (see
    /// `flushPendingReplay`). Must run on the main actor.
    @MainActor
    func handlePeerConnected(_ peerID: String) {
        if Self.shouldReplayOnConnect(peerID: peerID, known: attachedPeerIDs) {
            pendingReplayPeerIDs.insert(peerID)
        }
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
        flushPendingReplay(for: peerID)
        // bridge.send is thread-safe (internal writeQueue).
        bridge.send(text)
    }

    @MainActor
    private func flushPendingReplay(for peerID: String) {
        guard pendingReplayPeerIDs.remove(peerID) != nil else { return }
        replayScrollback(to: peerID)
    }

    // MARK: - Broadcast

    /// Called by the ProcessBridge `onMessage` closure (runs on a background queue).
    /// State access and peer sends are hopped to the main actor to avoid races.
    func broadcast(_ text: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.appendScrollback(text)
            let recipients = Self.outputRecipients(attached: self.attachedPeerIDs, isAuthorized: self.isAuthorized)
            for peerID in recipients {
                if self.pendingReplayPeerIDs.contains(peerID) {
                    // Reconnected peer now authorised: the replay already
                    // includes `text` (just appended above).
                    self.flushPendingReplay(for: peerID)
                } else {
                    try? await self.cm.sendText(text, to: peerID)
                }
            }
        }
    }

    /// Replays the bounded scrollback to a newly (re)attached peer.
    /// State access and sends are confined to the main actor.
    func replayScrollback(to peerID: String) {
        Task { @MainActor [weak self] in
            guard let self, self.isAuthorized(peerID) else { return }
            for line in self.scrollback {
                try? await self.cm.sendText(line, to: peerID)
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
