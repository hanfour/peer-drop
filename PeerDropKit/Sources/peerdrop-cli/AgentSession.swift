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

    // MARK: - Properties

    private let bridge: ProcessBridge
    private let cm: ConnectionManager
    private let store: TrustedContactStore

    /// Peers whose messages have been received in this session.
    /// Confined to the main actor.
    private var attachedPeerIDs = Set<String>()

    /// Bounded scrollback of outgoing (bridge→peers) messages.
    /// Confined to the main actor.
    private var scrollback: [String] = []

    private static let scrollbackCap = 200

    // MARK: - Init

    init(
        bridge: ProcessBridge,
        connectionManager: ConnectionManager,
        store: TrustedContactStore
    ) {
        self.bridge = bridge
        self.cm = connectionManager
        self.store = store
    }

    // MARK: - Wiring

    /// Installs the `onTextMessageReceived` hook on the ConnectionManager.
    /// Must be called from the main actor (ConnectionManager is main-actor bound).
    @MainActor
    func wire() {
        cm.onTextMessageReceived = { [weak self] peerID, text in
            // Confine the attachedPeerIDs mutation explicitly to the main actor so
            // this code remains correct even if the call-site actor context ever
            // changes (e.g. ConnectionManager loses its @MainActor annotation).
            // bridge.send is thread-safe (internal writeQueue) and stays outside the hop.
            Task { @MainActor [weak self] in
                self?.attachedPeerIDs.insert(peerID)
            }
            self?.bridge.send(text)
        }
    }

    // MARK: - Broadcast

    /// Called by the ProcessBridge `onMessage` closure (runs on a background queue).
    /// State access and peer sends are hopped to the main actor to avoid races.
    func broadcast(_ text: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.appendScrollback(text)
            for peerID in self.attachedPeerIDs {
                try? await self.cm.sendText(text, to: peerID)
            }
        }
    }

    /// Replays the bounded scrollback to a newly (re)attached peer.
    /// State access and sends are confined to the main actor.
    func replayScrollback(to peerID: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
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
