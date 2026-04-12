import Foundation
import UIKit

struct PeerIdentity: Codable, Identifiable, Hashable {
    let id: String
    let displayName: String
    let certificateFingerprint: String?
    /// Curve25519 public key for E2E encryption (32 bytes). Stored property so it survives Codable serialization over the wire.
    let identityPublicKey: Data?
    /// Human-readable fingerprint of the identity public key
    let identityFingerprint: String?

    init(displayName: String, certificateFingerprint: String? = nil, identityPublicKey: Data? = nil, identityFingerprint: String? = nil) {
        self.id = UUID().uuidString
        self.displayName = displayName
        self.certificateFingerprint = certificateFingerprint
        self.identityPublicKey = identityPublicKey
        self.identityFingerprint = identityFingerprint
    }

    init(id: String, displayName: String, certificateFingerprint: String? = nil, identityPublicKey: Data? = nil, identityFingerprint: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.certificateFingerprint = certificateFingerprint
        self.identityPublicKey = identityPublicKey
        self.identityFingerprint = identityFingerprint
    }

    private static let localIDKey = "peerDropLocalIdentityID"

    /// Alias for `local()` — returns the current device's identity.
    static var current: PeerIdentity { local() }

    static func local(certificateFingerprint: String? = nil) -> PeerIdentity {
        let name = UserDefaults.standard.string(forKey: "peerDropDisplayName") ?? UIDevice.current.name

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
            identityFingerprint: IdentityKeyManager.shared.fingerprint
        )
    }
}
