import Foundation
import PeerDropCore
import PeerDropSecurity

/// The facts about one peer connection that decide whether text from that
/// peer may be written into the wrapped process (PTY / agent). Kept as a plain
/// value so the policy can be unit-tested without sockets.
struct InputAuthFacts: Equatable {
    /// `secureChannelState == .secured`.
    var isSecured: Bool
    /// Identity key actually used in the LocalSecureChannel handshake.
    var handshakeIdentityKey: Data?
    /// Identity key the peer claimed in its hello (`peerIdentity.identityPublicKey`).
    var helloIdentityKey: Data?
    /// Pinning verdict for the connection. `.matched` = verified contact, or a
    /// first-trust SAS the local user confirmed this session.
    var pinningVerdict: PeerConnection.PinningVerdict
    /// The handshake key belongs to a non-blocked contact at `.linked`/`.verified`.
    var handshakeKeyTrusted: Bool
}

/// Security gate for issue #166: peer text reaches the shell ONLY from an
/// authenticated, user-approved peer over an encrypted channel.
enum InputGate {

    /// Pure policy. Fails closed on every missing fact.
    static func shouldForwardInput(_ facts: InputAuthFacts?) -> Bool {
        guard let facts, facts.isSecured else { return false }
        guard let handshakeKey = facts.handshakeIdentityKey,
              let helloKey = facts.helloIdentityKey,
              !handshakeKey.isEmpty,
              handshakeKey == helloKey
        else { return false }
        guard facts.pinningVerdict == .matched else { return false }
        return facts.handshakeKeyTrusted
    }

    /// The connection `peerID` currently resolves to, if and only if it passes
    /// the gate. Callers that send to the peer must send on THIS object, in the
    /// same main-actor turn, so a connection that takes over the peer ID later
    /// can never receive what was approved for this one.
    @MainActor
    static func approvedConnection(for peerID: String, cm: ConnectionManager, store: TrustedContactStore) -> PeerConnection? {
        guard let conn = cm.connection(for: peerID),
              shouldForwardInput(facts(of: conn, store: store))
        else { return nil }
        return conn
    }

    /// Gathers the facts for the connection the hook's `peerID` resolves to.
    /// Returns nil when there is no such connection (caller must fail closed).
    @MainActor
    static func facts(for peerID: String, cm: ConnectionManager, store: TrustedContactStore) -> InputAuthFacts? {
        guard let conn = cm.connection(for: peerID) else { return nil }
        return facts(of: conn, store: store)
    }

    @MainActor
    static func facts(of conn: PeerConnection, store: TrustedContactStore) -> InputAuthFacts {
        let handshakeKey = conn.handshakePeerIdentityKey
        var trusted = false
        if let handshakeKey, let contact = store.find(byPublicKey: handshakeKey) {
            trusted = !contact.isBlocked && contact.trustLevel != .unknown
        }
        return InputAuthFacts(
            isSecured: conn.secureChannelState == .secured,
            handshakeIdentityKey: handshakeKey,
            helloIdentityKey: conn.peerIdentity.identityPublicKey,
            pinningVerdict: conn.pinningVerdict,
            handshakeKeyTrusted: trusted
        )
    }
}
