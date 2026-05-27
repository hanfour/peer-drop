import Foundation
import PeerDropPlatform

public struct PeerIdentity: Codable, Identifiable, Hashable {
    public let id: String
    public let displayName: String
    public let certificateFingerprint: String?
    /// Curve25519 public key for E2E encryption (32 bytes). Stored property so it survives Codable serialization over the wire.
    public let identityPublicKey: Data?
    /// Human-readable fingerprint of the identity public key
    public let identityFingerprint: String?
    /// v5.1+: peer supports `LocalSecureChannel` (Double Ratchet over local
    /// TCP). Both sides must report `true` before either initiates a
    /// handshake — otherwise we'd send a `.secureHandshake` PeerMessage
    /// type that v5.0.x peers don't recognize, which would either crash
    /// their JSON decoder or get silently dropped, leaving the channel
    /// half-up. v5.0.x and earlier wire payloads decode this key as
    /// `false` via the custom decoder below.
    public let supportsSecureChannel: Bool

    public init(displayName: String, certificateFingerprint: String? = nil, identityPublicKey: Data? = nil, identityFingerprint: String? = nil, supportsSecureChannel: Bool = true) {
        self.id = UUID().uuidString
        self.displayName = displayName
        self.certificateFingerprint = certificateFingerprint
        self.identityPublicKey = identityPublicKey
        self.identityFingerprint = identityFingerprint
        self.supportsSecureChannel = supportsSecureChannel
    }

    public init(id: String, displayName: String, certificateFingerprint: String? = nil, identityPublicKey: Data? = nil, identityFingerprint: String? = nil, supportsSecureChannel: Bool = true) {
        self.id = id
        self.displayName = displayName
        self.certificateFingerprint = certificateFingerprint
        self.identityPublicKey = identityPublicKey
        self.identityFingerprint = identityFingerprint
        self.supportsSecureChannel = supportsSecureChannel
    }

    // MARK: - Codable (backward-compat decode)

    private enum CodingKeys: String, CodingKey {
        case id, displayName, certificateFingerprint
        case identityPublicKey, identityFingerprint
        case supportsSecureChannel
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.certificateFingerprint = try c.decodeIfPresent(String.self, forKey: .certificateFingerprint)
        self.identityPublicKey = try c.decodeIfPresent(Data.self, forKey: .identityPublicKey)
        self.identityFingerprint = try c.decodeIfPresent(String.self, forKey: .identityFingerprint)
        // Default `false` for v5.0.x peers whose hello payload doesn't
        // include the key. Local()'s default sets true going forward.
        self.supportsSecureChannel = try c.decodeIfPresent(Bool.self, forKey: .supportsSecureChannel) ?? false
    }

    private static let localIDKey = "peerDropLocalIdentityID"

    /// Alias for `local()` — returns the current device's identity.
    @MainActor
    public static var current: PeerIdentity { local() }

    @MainActor
    public static func local(certificateFingerprint: String? = nil) -> PeerIdentity {
        let name = UserDefaults.standard.string(forKey: "peerDropDisplayName")
            ?? PlatformDependencies.shared.deviceName().currentName

        // Persist local identity ID so message history survives across launches
        let stableID: String
        if let saved = UserDefaults.standard.string(forKey: localIDKey) {
            stableID = saved
        } else {
            stableID = UUID().uuidString
            UserDefaults.standard.set(stableID, forKey: localIDKey)
        }

        return PeerIdentity(
            id: stableID,
            displayName: name,
            certificateFingerprint: certificateFingerprint,
            identityPublicKey: IdentityKeyManager.shared.publicKey.rawRepresentation,
            identityFingerprint: IdentityKeyManager.shared.fingerprint,
            supportsSecureChannel: true
        )
    }
}
