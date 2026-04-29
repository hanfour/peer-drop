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
}
