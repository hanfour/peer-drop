import Foundation

/// Wire-format envelope for remote encrypted messages via the mailbox relay.
/// Contains both sender identification (for first-contact) and encrypted payload.
struct RemoteMessageEnvelope: Codable {
    let senderIdentityKey: Data         // Sender's Curve25519 identity public key (always present)
    let senderMailboxId: String         // Sender's mailbox ID (for reply routing)
    let senderDisplayName: String?      // Sender's display name (for first-contact contact creation)
    let ephemeralKey: Data?             // X3DH ephemeral key (only for initial message)
    let usedSignedPreKeyId: UInt32?     // Which signed pre-key was used (only for initial message)
    let usedOneTimePreKeyId: UInt32?    // Which OTP key was consumed (only for initial message)
    let ratchetMessage: RatchetMessage  // Double Ratchet encrypted payload

    /// Whether this is an X3DH initial message (session establishment)
    var isInitialMessage: Bool {
        ephemeralKey != nil && usedSignedPreKeyId != nil
    }
}
