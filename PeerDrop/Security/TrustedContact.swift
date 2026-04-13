import Foundation
import CryptoKit

struct TrustedContact: Codable, Identifiable {
    let id: UUID
    var deviceId: String?                    // Stable peer device ID (PeerIdentity.id)
    var displayName: String
    var identityPublicKey: Data              // Curve25519 public key (32 bytes)
    var trustLevel: TrustLevel
    let firstConnected: Date
    var lastVerified: Date?
    var mailboxId: String?                   // Future: remote mailbox ID
    var userId: String?                      // Future: account user ID
    var petSnapshot: Data?                   // Future: peer's pet snapshot
    var isBlocked: Bool

    init(
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
        isBlocked: Bool = false
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
    }

    var keyFingerprint: String {
        let hash = SHA256.hash(data: identityPublicKey)
        let hex = hash.prefix(10).map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: 20, by: 4).map { i in
            let start = hex.index(hex.startIndex, offsetBy: i)
            let end = hex.index(start, offsetBy: 4)
            return String(hex[start..<end])
        }.joined(separator: " ")
    }

    func matchesKey(_ otherPublicKey: Data) -> Bool {
        identityPublicKey == otherPublicKey
    }

    func cryptoPublicKey() throws -> Curve25519.KeyAgreement.PublicKey {
        try Curve25519.KeyAgreement.PublicKey(rawRepresentation: identityPublicKey)
    }
}
