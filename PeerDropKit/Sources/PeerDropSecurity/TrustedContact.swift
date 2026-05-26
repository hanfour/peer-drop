import Foundation
import CryptoKit

public struct TrustedContact: Codable, Identifiable {
    public let id: UUID
    public var deviceId: String?                    // Stable peer device ID (PeerIdentity.id)
    public var displayName: String
    public var identityPublicKey: Data              // Curve25519 public key (32 bytes)
    public var trustLevel: TrustLevel
    public let firstConnected: Date
    public var lastVerified: Date?
    public var mailboxId: String?                   // Future: remote mailbox ID
    public var userId: String?                      // Future: account user ID
    public var petSnapshot: Data?                   // Future: peer's pet snapshot
    public var isBlocked: Bool
    /// Audit trail of identity-key rotations observed on this contact.
    /// Bounded to a small number of entries by `TrustedContactStore`.
    public var keyHistory: [KeyChangeRecord]
    /// v5.4 PR7: detected protocol generation of this peer. Set from
    /// `RemoteMessageEnvelope.protocolVersion` on first inbound contact
    /// or any subsequent inbound message (responder-side; see
    /// `ConnectionManager.handleRemoteMessage` and `approveFirstContact`).
    /// Initiator-side persistence is deferred to a follow-up — initiator
    /// C2 routing uses the live `X3DH.verifyBundleFreshness` result during
    /// `RemoteSessionManager.initiateSession`, so peerProtocolVersion is
    /// not strictly required on the initiator side today.
    /// nil for legacy contacts persisted before v5.4 (these decode as nil
    /// and are treated as `.unknown` at use sites).
    public var peerProtocolVersion: PeerVersion?

    public init(
        id: UUID = UUID(),
        deviceId: String? = nil,
        displayName: String,
        identityPublicKey: Data,
        trustLevel: TrustLevel,
        firstConnected: Date = Date(),
        lastVerified: Date? = nil,
        mailboxId: String? = nil,
        userId: String? = nil,
        petSnapshot: Data? = nil,
        isBlocked: Bool = false,
        keyHistory: [KeyChangeRecord] = [],
        peerProtocolVersion: PeerVersion? = nil
    ) {
        self.id = id
        self.deviceId = deviceId
        self.displayName = displayName
        self.identityPublicKey = identityPublicKey
        self.trustLevel = trustLevel
        self.firstConnected = firstConnected
        self.lastVerified = lastVerified
        self.mailboxId = mailboxId
        self.userId = userId
        self.petSnapshot = petSnapshot
        self.isBlocked = isBlocked
        self.keyHistory = keyHistory
        self.peerProtocolVersion = peerProtocolVersion
    }

    // Custom decode so legacy on-disk records (no `keyHistory`, no `isBlocked`)
    // continue to load without error after upgrading to v3.4+.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.deviceId = try c.decodeIfPresent(String.self, forKey: .deviceId)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.identityPublicKey = try c.decode(Data.self, forKey: .identityPublicKey)
        self.trustLevel = try c.decode(TrustLevel.self, forKey: .trustLevel)
        self.firstConnected = try c.decode(Date.self, forKey: .firstConnected)
        self.lastVerified = try c.decodeIfPresent(Date.self, forKey: .lastVerified)
        self.mailboxId = try c.decodeIfPresent(String.self, forKey: .mailboxId)
        self.userId = try c.decodeIfPresent(String.self, forKey: .userId)
        self.petSnapshot = try c.decodeIfPresent(Data.self, forKey: .petSnapshot)
        self.isBlocked = try c.decodeIfPresent(Bool.self, forKey: .isBlocked) ?? false
        self.keyHistory = try c.decodeIfPresent([KeyChangeRecord].self, forKey: .keyHistory) ?? []
        self.peerProtocolVersion = try c.decodeIfPresent(PeerVersion.self, forKey: .peerProtocolVersion)
    }

    public var keyFingerprint: String {
        let hash = SHA256.hash(data: identityPublicKey)
        let hex = hash.prefix(10).map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: 20, by: 4).map { i in
            let start = hex.index(hex.startIndex, offsetBy: i)
            let end = hex.index(start, offsetBy: 4)
            return String(hex[start..<end])
        }.joined(separator: " ")
    }

    public func matchesKey(_ otherPublicKey: Data) -> Bool {
        identityPublicKey == otherPublicKey
    }

    public func cryptoPublicKey() throws -> Curve25519.KeyAgreement.PublicKey {
        try Curve25519.KeyAgreement.PublicKey(rawRepresentation: identityPublicKey)
    }
}

// MARK: - Key Rotation Audit Trail

/// A record of an identity-key rotation observed on a `TrustedContact`.
/// Used for post-incident forensics — never displayed in regular UI.
public struct KeyChangeRecord: Codable, Hashable {
    public let oldKey: Data
    public let newKey: Data
    public let changedAt: Date
    public let reason: KeyChangeReason

    public init(oldKey: Data, newKey: Data, changedAt: Date, reason: KeyChangeReason) {
        self.oldKey = oldKey
        self.newKey = newKey
        self.changedAt = changedAt
        self.reason = reason
    }
}

public enum KeyChangeReason: String, Codable {
    /// The peer presented a different identity key during a (re)connection
    /// without the user explicitly being prompted.
    case detectedOnReconnect
    /// The user explicitly approved the new key via the KeyChangeAlert UI
    /// (covers both "Accept" and "Verify Later" paths — both rotate the key).
    case userAcceptedNewKey
    /// Automatic record inserted when migrating a pre-v3.4 contact (no real rotation).
    case migratedFromLegacy
}
