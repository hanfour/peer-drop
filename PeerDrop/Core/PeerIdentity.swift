import Foundation
import UIKit

struct PeerIdentity: Codable, Identifiable, Hashable {
    let id: String
    let displayName: String
    let certificateFingerprint: String?

    init(displayName: String, certificateFingerprint: String? = nil) {
        self.id = UUID().uuidString
        self.displayName = displayName
        self.certificateFingerprint = certificateFingerprint
    }

    init(id: String, displayName: String, certificateFingerprint: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.certificateFingerprint = certificateFingerprint
    }

    private static let localIDKey = "peerDropLocalIdentityID"

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
            certificateFingerprint: certificateFingerprint
        )
    }
}
