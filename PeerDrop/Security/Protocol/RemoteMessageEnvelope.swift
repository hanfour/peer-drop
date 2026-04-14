import Foundation

/// Wire format for remote encrypted messages sent via the mailbox relay.
/// Contains the Double Ratchet ciphertext plus metadata needed for session setup.
struct RemoteMessageEnvelope: Codable {
    let senderIdentityKey: Data       // Sender's Curve25519 identity public key
    let ephemeralKey: Data            // Sender's X3DH ephemeral public key (for first message)
    let usedSignedPreKeyId: UInt32    // Which signed pre-key was used in X3DH
    let usedOneTimePreKeyId: UInt32?  // Which OTP key was consumed (nil if none available)
    let ratchetMessage: RatchetMessage // The Double Ratchet encrypted payload
}
