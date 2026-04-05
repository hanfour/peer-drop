import Foundation

enum PetLevel: Int, Codable, Comparable, CaseIterable {
    case egg = 1
    case baby = 2
    // Future: child = 3, teen = 4, mature = 5, ultimate = 6

    static func < (lhs: PetLevel, rhs: PetLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
