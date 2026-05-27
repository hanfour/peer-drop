import Foundation
import PeerDropProtocol

extension PeerMessage {
    /// Factory that constructs a hello-type message from a PeerIdentity.
    /// Lives in PeerDropSecurity because PeerIdentity (and LocalSecureChannel
    /// for the sibling `secureHandshake(bundle:senderID:)` factory) live
    /// here. PeerDropProtocol intentionally does not depend on PeerDrop-
    /// Security, so the extension is declared from the Security side.
    public static func hello(identity: PeerIdentity) throws -> PeerMessage {
        let data = try JSONEncoder().encode(identity)
        return PeerMessage(type: .hello, payload: data, senderID: identity.id)
    }

    /// Plaintext-on-wire handshake bundle. Sender's identity public key +
    /// fresh ephemeral ratchet public key. Both peers exchange these to
    /// bootstrap a LocalSecureChannel.
    public static func secureHandshake(bundle: LocalSecureChannel.HandshakeBundle, senderID: String) throws -> PeerMessage {
        let data = try JSONEncoder().encode(bundle)
        return PeerMessage(type: .secureHandshake, payload: data, senderID: senderID)
    }

}
