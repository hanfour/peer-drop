import Foundation

/// The facts about one peer connection that decide whether a notes-account
/// exchange may happen on it (spec §4.1, §10.1, §10.3, §10.4). A plain value so
/// the policy is unit-testable without sockets; the caller (CM) gathers them
/// from the SAME `PeerConnection` it will send on. Mirrors `InputAuthFacts`.
public struct NotesExchangeFacts: Equatable, Sendable {

    /// Fail-closed view of `PeerConnection.PinningVerdict`.
    public enum Pinning: Equatable, Sendable {
        /// `.matched` or `.firstTrust`: the only passing values.
        case trusted
        /// `.notChecked`: pinning has not run yet. Denied.
        case notEvaluated
        /// `.mismatch`. Denied.
        case mismatch

        public init(_ verdict: PeerConnection.PinningVerdict) {
            switch verdict {
            case .matched, .firstTrust: self = .trusted
            case .notChecked: self = .notEvaluated
            case .mismatch: self = .mismatch
            }
        }
    }

    /// `secureChannelState == .secured`.
    public var isSecured: Bool
    /// Identity key actually used in the LocalSecureChannel handshake
    /// (`handshakePeerIdentityKey`).
    public var handshakeKey: Data?
    /// Identity key the peer claimed in its HELLO (`peerIdentity.identityPublicKey`).
    public var helloKey: Data?
    /// Outcome of the connection's TOFU pinning (computed from the HELLO key,
    /// so it only means something together with handshakeKey == helloKey).
    public var pinning: Pinning
    /// Local direct TCP (Bonjour / manual IP). False for relay AND tailnet.
    public var isLocalDirect: Bool
    /// Peer's HELLO declared `supportsNotesExchange`.
    public var peerSupportsExchange: Bool
    /// This build/connection advertised `supportsNotesExchange`.
    public var localSupportsExchange: Bool

    public init(isSecured: Bool, handshakeKey: Data?, helloKey: Data?,
                pinning: Pinning, isLocalDirect: Bool,
                peerSupportsExchange: Bool, localSupportsExchange: Bool) {
        self.isSecured = isSecured
        self.handshakeKey = handshakeKey
        self.helloKey = helloKey
        self.pinning = pinning
        self.isLocalDirect = isLocalDirect
        self.peerSupportsExchange = peerSupportsExchange
        self.localSupportsExchange = localSupportsExchange
    }

    /// Convenience: map the connection's verdict. Only `.matched` / `.firstTrust`
    /// pass; `.notChecked` is denied (`pinningNotEvaluated`).
    public init(verdict: PeerConnection.PinningVerdict, isSecured: Bool,
                handshakeKey: Data?, helloKey: Data?, isLocalDirect: Bool,
                peerSupportsExchange: Bool, localSupportsExchange: Bool) {
        self.init(isSecured: isSecured, handshakeKey: handshakeKey, helloKey: helloKey,
                  pinning: Pinning(verdict), isLocalDirect: isLocalDirect,
                  peerSupportsExchange: peerSupportsExchange,
                  localSupportsExchange: localSupportsExchange)
    }
}

/// Pure gate for the notes exchange. Fails closed: every condition must hold.
///
/// CM contract (Task 4): evaluate on the SAME `PeerConnection` the exchange
/// uses, and re-evaluate both when an exchange message is RECEIVED and right
/// before a reveal is SENT (state can change in between, e.g. a re-handshake
/// or a pinning mismatch). A denial at either point drops the message / sends
/// nothing.
public enum NotesExchangeGate {

    public enum Reason: Equatable, Sendable {
        case notSecured
        /// Handshake key absent or not a 32-byte X25519 key.
        case handshakeKeyMissing
        /// HELLO key absent or not a 32-byte X25519 key.
        case helloKeyMissing
        /// Handshake key ≠ HELLO-claimed key.
        case handshakeKeyMismatch
        /// Pinning verdict still `.notChecked`.
        case pinningNotEvaluated
        case pinningMismatch
        /// Relay, tailnet, or any non-local transport.
        case notLocalDirect
        case localLacksSupport
        case peerLacksSupport
    }

    public enum Result: Equatable, Sendable {
        case allowed
        case denied(Reason)
    }

    static let keyLength = 32

    /// Checks in a fixed order; the first failing condition is reported.
    public static func evaluate(_ facts: NotesExchangeFacts) -> Result {
        guard facts.isSecured else { return .denied(.notSecured) }
        guard let hs = facts.handshakeKey, hs.count == keyLength else { return .denied(.handshakeKeyMissing) }
        guard let hello = facts.helloKey, hello.count == keyLength else { return .denied(.helloKeyMissing) }
        guard hs == hello else { return .denied(.handshakeKeyMismatch) }
        switch facts.pinning {
        case .trusted: break
        case .notEvaluated: return .denied(.pinningNotEvaluated)
        case .mismatch: return .denied(.pinningMismatch)
        }
        guard facts.isLocalDirect else { return .denied(.notLocalDirect) }
        guard facts.localSupportsExchange else { return .denied(.localLacksSupport) }
        guard facts.peerSupportsExchange else { return .denied(.peerLacksSupport) }
        return .allowed
    }
}
