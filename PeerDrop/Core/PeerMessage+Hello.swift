import Foundation
import PeerDropProtocol

extension PeerMessage {
    /// Factory that constructs a hello-type message from a PeerIdentity.
    /// Lives in PeerDrop/Core/ (not in PeerDropProtocol module) because
    /// PeerIdentity is currently in PeerDrop/Core/ — M1d-2 keeps the
    /// inter-module dep at the Core layer rather than forcing
    /// PeerDropProtocol to depend on PeerDropSecurity/PeerDropCore.
    static func hello(identity: PeerIdentity) throws -> PeerMessage {
        let data = try JSONEncoder().encode(identity)
        return PeerMessage(type: .hello, payload: data, senderID: identity.id)
    }

    /// Plaintext-on-wire handshake bundle. Sender's identity public key +
    /// fresh ephemeral ratchet public key. Both peers exchange these to
    /// bootstrap a LocalSecureChannel.
    static func secureHandshake(bundle: LocalSecureChannel.HandshakeBundle, senderID: String) throws -> PeerMessage {
        let data = try JSONEncoder().encode(bundle)
        return PeerMessage(type: .secureHandshake, payload: data, senderID: senderID)
    }

    static func fileOffer(metadata: TransferMetadata, senderID: String) throws -> PeerMessage {
        let data = try JSONEncoder().encode(metadata)
        return PeerMessage(type: .fileOffer, payload: data, senderID: senderID)
    }

    static func batchStart(metadata: BatchMetadata, senderID: String) throws -> PeerMessage {
        let data = try JSONEncoder().encode(metadata)
        return PeerMessage(type: .batchStart, payload: data, senderID: senderID)
    }
}
