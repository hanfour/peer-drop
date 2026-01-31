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

    static func local(certificateFingerprint: String? = nil) -> PeerIdentity {
        let name = UserDefaults.standard.string(forKey: "peerDropDisplayName") ?? UIDevice.current.name
        return PeerIdentity(
            displayName: name,
            certificateFingerprint: certificateFingerprint
        )
    }
}
