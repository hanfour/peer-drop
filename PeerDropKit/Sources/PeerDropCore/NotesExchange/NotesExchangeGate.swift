import Foundation

/// The facts about one peer connection that decide whether a notes-account
/// exchange may happen on it (spec §4.1, §10.1, §10.3, §10.4). A plain value so
/// the policy is unit-testable without sockets; the caller (CM) gathers them
/// from the SAME `PeerConnection` it will send on. Mirrors `InputAuthFacts`.
public struct NotesExchangeFacts: Equatable, Sendable {
    /// `secureChannelState == .secured`.
    public var isSecured: Bool
    /// Identity key actually used in the LocalSecureChannel handshake
    /// (`handshakePeerIdentityKey`).
    public var handshakeKey: Data?
    /// Identity key the peer claimed in its HELLO (`peerIdentity.identityPublicKey`).
    public var helloKey: Data?
    /// `pinningVerdict` is `.mismatch` (pinning is computed from the HELLO key,
    /// so this only holds together with handshakeKey == helloKey).
    public var pinningVerdictIsMismatch: Bool
    /// Local direct TCP (Bonjour / manual IP). False for relay AND tailnet.
    public var isLocalDirect: Bool
    /// Peer's HELLO declared `supportsNotesExchange`.
    public var peerSupportsExchange: Bool
    /// This build/connection advertised `supportsNotesExchange`.
    public var localSupportsExchange: Bool

    public init(isSecured: Bool, handshakeKey: Data?, helloKey: Data?,
                pinningVerdictIsMismatch: Bool, isLocalDirect: Bool,
                peerSupportsExchange: Bool, localSupportsExchange: Bool) {
        self.isSecured = isSecured
        self.handshakeKey = handshakeKey
        self.helloKey = helloKey
        self.pinningVerdictIsMismatch = pinningVerdictIsMismatch
        self.isLocalDirect = isLocalDirect
        self.peerSupportsExchange = peerSupportsExchange
        self.localSupportsExchange = localSupportsExchange
    }

    /// Convenience: derive the mismatch flag from the connection's verdict.
    /// `.firstTrust`, `.matched` and `.notChecked` are not mismatches (an
    /// unsecured connection is already denied by `isSecured`).
    public init(verdict: PeerConnection.PinningVerdict, isSecured: Bool,
                handshakeKey: Data?, helloKey: Data?, isLocalDirect: Bool,
                peerSupportsExchange: Bool, localSupportsExchange: Bool) {
        let isMismatch: Bool
        if case .mismatch = verdict { isMismatch = true } else { isMismatch = false }
        self.init(isSecured: isSecured, handshakeKey: handshakeKey, helloKey: helloKey,
                  pinningVerdictIsMismatch: isMismatch, isLocalDirect: isLocalDirect,
                  peerSupportsExchange: peerSupportsExchange,
                  localSupportsExchange: localSupportsExchange)
    }
}

/// Pure gate for the notes exchange. Fails closed: every condition must hold.
public enum NotesExchangeGate {

    public enum Reason: Equatable, Sendable {
        case notSecured
        /// Handshake key absent or not a 32-byte X25519 key.
        case handshakeKeyMissing
        /// HELLO key absent or not a 32-byte X25519 key.
        case helloKeyMissing
        /// Handshake key ≠ HELLO-claimed key.
        case handshakeKeyMismatch
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
        guard !facts.pinningVerdictIsMismatch else { return .denied(.pinningMismatch) }
        guard facts.isLocalDirect else { return .denied(.notLocalDirect) }
        guard facts.localSupportsExchange else { return .denied(.localLacksSupport) }
        guard facts.peerSupportsExchange else { return .denied(.peerLacksSupport) }
        return .allowed
    }
}
