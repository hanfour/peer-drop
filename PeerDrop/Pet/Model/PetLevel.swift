import Foundation

enum PetLevel: Int, Codable, Comparable, CaseIterable {
    case egg = 1
    case baby = 2
    case child = 3

    static func < (lhs: PetLevel, rhs: PetLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
