import Foundation

/// Pet lifecycle stage. Persisted via Codable rawValue.
///
/// **rawValue 1 is reserved**: it was `.egg` in v3.x. v4.0.1 removed
/// the egg stage but the decoder maps any persisted/peer-sent
/// `rawValue 1` to `.baby` for backward compatibility (v3.x users on
/// upgrade, cross-version peer payloads, iCloud restore from older
/// devices).
enum PetLevel: Int, Codable, Comparable, CaseIterable {
    case baby = 2
    case adult = 3   // legacy "child" — rawValue stays 3 so persisted/network data migrates without a custom decoder
    case elder = 4

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(Int.self)
        // rawValue 1 = legacy .egg → .baby; any unknown future raw also falls to .baby
        self = PetLevel(rawValue: raw) ?? .baby
    }

    static func < (lhs: PetLevel, rhs: PetLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var displayName: String {
        switch self {
        case .baby: return "幼年"
        case .adult: return "成熟"
        case .elder: return "老年"
        }
    }

    var assetSlug: String {
        switch self {
        case .baby: return "baby"
        case .adult: return "adult"
        case .elder: return "elder"
        }
    }
}
