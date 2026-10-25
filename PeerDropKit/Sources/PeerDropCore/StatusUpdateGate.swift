import Foundation

/// The facts about one peer connection that decide whether a `.statusUpdate`
/// frame may be sent or accepted on it (Project F2). A plain value so the
/// policy is unit-testable without sockets; the caller (CM) gathers them from
/// the SAME `PeerConnection` it sends or receives on. Mirrors `NotesExchangeFacts`.
public struct StatusUpdateFacts: Equatable, Sendable {
    /// Still the installed, live entry: in `connections` and connected, or in
    /// `rendezvousConnections` and verified.
    public var isInstalled: Bool
    /// `secureChannelState == .secured` with a channel present.
    public var isSecured: Bool
    /// Identity key actually used in the LocalSecureChannel handshake.
    public var handshakeKey: Data?
    /// Identity key the peer claimed in its HELLO (pinned key for rendezvous).
    public var helloKey: Data?
    /// Outcome of the connection's pinning; only `.trusted` passes.
    public var pinning: NotesExchangeFacts.Pinning
    /// The peer advertised `supportsStatusUpdate` on this connection.
    public var peerSupports: Bool
    /// The HELLO we sent on this connection advertised `supportsStatusUpdate`.
    public var localAdvertised: Bool

    public init(isInstalled: Bool, isSecured: Bool, handshakeKey: Data?, helloKey: Data?,
                pinning: NotesExchangeFacts.Pinning, peerSupports: Bool, localAdvertised: Bool) {
        self.isInstalled = isInstalled
        self.isSecured = isSecured
        self.handshakeKey = handshakeKey
        self.helloKey = helloKey
        self.pinning = pinning
        self.peerSupports = peerSupports
        self.localAdvertised = localAdvertised
    }
}

/// Pure gate for `.statusUpdate`. Fails closed: every condition must hold.
/// An older peer fails the whole connection on an unknown `MessageType`, so a
/// denial means the frame is never sent (and a received one is dropped).
public enum StatusUpdateGate {
    public static func allows(_ f: StatusUpdateFacts) -> Bool {
        guard f.isInstalled, f.isSecured, f.pinning == .trusted,
              let hs = f.handshakeKey, let hello = f.helloKey, hs == hello,
              f.peerSupports, f.localAdvertised else { return false }
        return true
    }
}
