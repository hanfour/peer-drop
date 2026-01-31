import Foundation

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
        PeerIdentity(
            displayName: UIDevice.current.name,
            certificateFingerprint: certificateFingerprint
        )
    }
}

import UIKit
