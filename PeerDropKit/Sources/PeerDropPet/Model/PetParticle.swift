import CoreGraphics
import Foundation

public enum ParticleType: String {
    case heart, zzz, sweat, poop, star
}

public struct PetParticle: Identifiable {
    public let id = UUID()
    public let type: ParticleType
    public var position: CGPoint
    public let velocity: CGVector
    public let lifetime: TimeInterval
    public let createdAt: Date = Date()

    public init(type: ParticleType, position: CGPoint, velocity: CGVector, lifetime: TimeInterval) {
        self.type = type; self.position = position; self.velocity = velocity; self.lifetime = lifetime
    }

    public var isExpired: Bool {
        Date().timeIntervalSince(createdAt) > lifetime
    }
}

extension ParticleType {
    public var emoji: String {
        switch self {
        case .heart: return "\u{2764}\u{FE0F}"
        case .zzz: return "\u{1F4A4}"
        case .sweat: return "\u{1F4A6}"
        case .poop: return "\u{1F4A9}"
        case .star: return "\u{2B50}"
        }
    }
}
