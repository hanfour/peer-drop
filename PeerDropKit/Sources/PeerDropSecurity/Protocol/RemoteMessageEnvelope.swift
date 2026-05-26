import Foundation

/// Wire-format envelope for remote encrypted messages via the mailbox relay.
/// Contains both sender identification (for first-contact) and encrypted payload.
public struct RemoteMessageEnvelope: Codable {
    public let senderIdentityKey: Data         // Sender's Curve25519 identity public key (always present)
    public let senderMailboxId: String         // Sender's mailbox ID (for reply routing)
    public let senderDisplayName: String?      // Sender's display name (for first-contact contact creation)
    public let ephemeralKey: Data?             // X3DH ephemeral key (only for initial message)
    public let usedSignedPreKeyId: UInt32?     // Which signed pre-key was used (only for initial message)
    public let usedOneTimePreKeyId: UInt32?    // Which OTP key was consumed (only for initial message)
    public let ratchetMessage: RatchetMessage  // Double Ratchet encrypted payload
    /// v5.4 PR7 — peer's protocol generation.
    /// nil  → sender is v5.0–v5.3 (didn't emit the field).
    /// 1    → sender is v5.4+.
    /// Receivers map this to `PeerVersion` via
    /// `PeerVersion.from(envelopeProtocolVersion:)` (Task 7.3).
    /// Wire-compat: synthesized Codable treats absent key as nil, so
    /// old senders decoded by new receivers continue to work unchanged.
    public let protocolVersion: UInt8?

    /// Whether this is an X3DH initial message (session establishment)
    public var isInitialMessage: Bool {
        ephemeralKey != nil && usedSignedPreKeyId != nil
    }

    /// Memberwise init with a default of `1` for `protocolVersion` so every
    /// v5.4+ construction site automatically emits the new field without
    /// requiring any call-site changes.  Synthetic legacy fixtures (e.g. tests
    /// that need the v5.0–v5.3 shape) can pass `protocolVersion: nil`.
    public init(
        senderIdentityKey: Data,
        senderMailboxId: String,
        senderDisplayName: String?,
        ephemeralKey: Data?,
        usedSignedPreKeyId: UInt32?,
        usedOneTimePreKeyId: UInt32?,
        ratchetMessage: RatchetMessage,
        protocolVersion: UInt8? = 1
    ) {
        self.senderIdentityKey = senderIdentityKey
        self.senderMailboxId = senderMailboxId
        self.senderDisplayName = senderDisplayName
        self.ephemeralKey = ephemeralKey
        self.usedSignedPreKeyId = usedSignedPreKeyId
        self.usedOneTimePreKeyId = usedOneTimePreKeyId
        self.ratchetMessage = ratchetMessage
        self.protocolVersion = protocolVersion
    }
}
