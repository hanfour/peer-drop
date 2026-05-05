import Foundation

enum PetLevel: Int, Codable, Comparable, CaseIterable {
    case egg = 1
    case baby = 2
    case adult = 3   // legacy "child" — rawValue stays 3 so persisted/network data migrates without a custom decoder
    case elder = 4

    static func < (lhs: PetLevel, rhs: PetLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var displayName: String {
        switch self {
        case .egg: return "蛋"
        case .baby: return "幼年"
        case .adult: return "成熟"
        case .elder: return "老年"
        }
    }

    /// Lowercase ASCII slug used in the asset filename convention
    /// `<species-id>-<assetSlug>.zip` (e.g. `cat-tabby-adult.zip`). Shared
    /// between the production resolver and test helpers — avoids per-call-site
    /// duplication of the same switch.
    var assetSlug: String {
        switch self {
        case .egg: return "egg"
        case .baby: return "baby"
        case .adult: return "adult"
        case .elder: return "elder"
        }
    }
}
