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
    /// Headless peer (e.g. the `peerdrop-cli` tool: a shell or AI agent). It has
    /// no audio device and no useful file handling, so the UI hides voice-call,
    /// voice-message, and file-transfer affordances for it. Older peers' hello
    /// payloads omit this key and decode as `false` (a normal user device).
    ///
    /// This is a self-reported UI hint, NOT a security boundary: a peer can claim
    /// any value, and the only effect is which affordances the UI offers (a peer
    /// spuriously claiming `true` would merely hide the local user's own
    /// send-file/call/mic buttons for that conversation — cosmetic, recoverable).
    public let isHeadless: Bool

    public init(displayName: String, certificateFingerprint: String? = nil, identityPublicKey: Data? = nil, identityFingerprint: String? = nil, supportsSecureChannel: Bool = true, isHeadless: Bool = false) {
        self.id = UUID().uuidString
        self.displayName = displayName
        self.certificateFingerprint = certificateFingerprint
        self.identityPublicKey = identityPublicKey
        self.identityFingerprint = identityFingerprint
        self.supportsSecureChannel = supportsSecureChannel
        self.isHeadless = isHeadless
    }

    public init(id: String, displayName: String, certificateFingerprint: String? = nil, identityPublicKey: Data? = nil, identityFingerprint: String? = nil, supportsSecureChannel: Bool = true, isHeadless: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.certificateFingerprint = certificateFingerprint
        self.identityPublicKey = identityPublicKey
        self.identityFingerprint = identityFingerprint
        self.supportsSecureChannel = supportsSecureChannel
        self.isHeadless = isHeadless
    }

    // MARK: - Codable (backward-compat decode)

    private enum CodingKeys: String, CodingKey {
        case id, displayName, certificateFingerprint
        case identityPublicKey, identityFingerprint
        case supportsSecureChannel
        case isHeadless
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
        // Older peers omit this; absent ⇒ a normal (non-headless) user device.
        self.isHeadless = try c.decodeIfPresent(Bool.self, forKey: .isHeadless) ?? false
    }

    private static let localIDKey = "peerDropLocalIdentityID"

    /// Alias for `local()` — returns the current device's identity.
    @MainActor
    public static var current: PeerIdentity { local() }

    @MainActor
    public static func local(certificateFingerprint: String? = nil) -> PeerIdentity {
        // When a CLI file-store namespace is active, use a per-instance
        // UserDefaults suite so the stable ID + display name persist per --name.
        // App path (nil) falls back to .standard — identical to prior behavior.
        let defaults: UserDefaults = {
            if let ns = PeerDropPersistence.fileStore?.namespace {
                return UserDefaults(suiteName: "com.peerdrop.cli.\(ns)") ?? .standard
            }
            return .standard
        }()

        let name = defaults.string(forKey: "peerDropDisplayName")
            ?? PlatformDependencies.shared.deviceName().currentName

        // Persist local identity ID so message history survives across launches
        let stableID: String
        if let saved = defaults.string(forKey: localIDKey) {
            stableID = saved
        } else {
            stableID = UUID().uuidString
            defaults.set(stableID, forKey: localIDKey)
        }

        return PeerIdentity(
            id: stableID,
            displayName: name,
            certificateFingerprint: certificateFingerprint,
            identityPublicKey: IdentityKeyManager.shared.publicKey.rawRepresentation,
            identityFingerprint: IdentityKeyManager.shared.fingerprint,
            supportsSecureChannel: true,
            // Only peerdrop-cli activates a file-store namespace; the app never
            // does. So an active file store cleanly marks this as a headless
            // terminal/agent peer rather than a real user device.
            isHeadless: PeerDropPersistence.fileStore != nil
        )
    }
}
