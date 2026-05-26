import Foundation
import PeerDropProtocol

/// A peer-message channel reference (e.g. a PeerConnection) that Transport
/// code can read display info from and send a PeerMessage through.
///
/// Conformance lives in the app target (`PeerConnection+MessageSendingPeer.swift`)
/// so Transport stays a leaf SPM module independent of Core types.
public protocol MessageSendingPeer: AnyObject {
    /// Display name of the remote peer this channel connects to. Used for
    /// caller UI labels (CallKit, voice-call panel, transfer toasts).
    var peerDisplayName: String { get }

    /// Send a single PeerMessage over this channel.
    func sendMessage(_ message: PeerMessage) async throws
}

/// The host that owns Transport types (file transfer, voice call, mailbox,
/// etc.) — typically `ConnectionManager` in the app target. Abstracts the
/// manager's API surface so Transport can be an independent SPM module
/// without depending on Core.
///
/// Methods are semantic ("transferDidStart", "voiceCallDidEnd") rather than
/// fine-grained property setters so the host can encapsulate the
/// corresponding UI/state transitions internally.
@MainActor
public protocol TransportHost: AnyObject {
    // MARK: - Identity

    /// Stable identifier for this device, used as `PeerMessage.senderID`.
    var localPeerID: String { get }

    /// Peer the user is currently focused on (e.g. chat tab open).
    /// Set/cleared by the UI; consulted by Transport when no explicit
    /// `peerID` is supplied to a send.
    var focusedPeerID: String? { get }

    /// Display name of the currently-connected peer in legacy single-
    /// connection mode, if any. Returns `nil` when in multi-connection mode
    /// or no peer is connected.
    var connectedPeerDisplayName: String? { get }

    // MARK: - Message channels

    /// Look up the active outbound message channel for a peer (if any).
    /// Returns the underlying `PeerConnection` adapted as `MessageSendingPeer`.
    func messageChannel(for peerID: String) -> MessageSendingPeer?

    /// Broadcast a message in legacy single-connection mode.
    func sendMessage(_ message: PeerMessage) async throws

    /// Send a message to a specific peer in multi-connection mode.
    func sendMessage(_ message: PeerMessage, to peerID: String) async throws

    // MARK: - Trust gate

    /// audit-#14: untrusted peers must not receive user-initiated content
    /// (file send, etc.). Transport consults the host so the trust source
    /// (TrustedContactStore + LocalSecureChannel state) stays in Core.
    func isPeerTrustedForUserActions(peerID: String) -> Bool

    // MARK: - Transfer UI coordination

    /// Notify the host that an inbound or outbound file transfer has begun.
    /// The host typically toggles the transfer-progress UI overlay.
    func transferDidStart()

    /// Notify the host that the active transfer has ended (success or
    /// failure). The host typically returns the UI to the connected state.
    func transferDidEnd()

    /// Append a completed transfer record to history and update the toast.
    func recordTransfer(_ record: TransferRecord)

    // MARK: - Voice call UI coordination

    /// Notify the host that a voice call has begun. The host typically
    /// transitions into the voice-call UI state.
    func voiceCallDidStart()

    /// Notify the host that the active voice call has ended.
    func voiceCallDidEnd()
}
