import CoreGraphics
import Foundation

enum ParticleType: String {
    case heart, zzz, sweat, poop, star
}

struct PetParticle: Identifiable {
    let id = UUID()
    let type: ParticleType
    var position: CGPoint
    let velocity: CGVector
    let lifetime: TimeInterval
    let createdAt: Date = Date()

    var isExpired: Bool {
        Date().timeIntervalSince(createdAt) > lifetime
    }
}

extension ParticleType {
    var emoji: String {
        switch self {
        case .heart: return "\u{2764}\u{FE0F}"
        case .zzz: return "\u{1F4A4}"
        case .sweat: return "\u{1F4A6}"
        case .poop: return "\u{1F4A9}"
        case .star: return "\u{2B50}"
        }
    }
}
