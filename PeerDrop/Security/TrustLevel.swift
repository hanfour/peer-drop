import Foundation

enum TrustLevel: String, Codable, Comparable {
    case verified   // lock.shield — face-to-face QR verified
    case linked     // link.circle — remote connected, not verified
    case unknown    // exclamationmark.triangle — unknown source

    var sfSymbol: String {
        switch self {
        case .verified: return "lock.shield"
        case .linked: return "link.circle"
        case .unknown: return "exclamationmark.triangle"
        }
    }

    var localizedLabel: String {
        switch self {
        case .verified: return String(localized: "Verified")
        case .linked: return String(localized: "Linked")
        case .unknown: return String(localized: "Unknown")
        }
    }

    func isAtLeast(_ level: TrustLevel) -> Bool {
        self >= level
    }

    private var rank: Int {
        switch self {
        case .verified: return 2
        case .linked: return 1
        case .unknown: return 0
        }
    }

    static func < (lhs: TrustLevel, rhs: TrustLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}
