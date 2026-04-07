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
