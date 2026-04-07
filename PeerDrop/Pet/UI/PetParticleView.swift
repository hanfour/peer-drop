import SwiftUI

struct PetParticleView: View {
    let particle: PetParticle
    @State private var opacity: Double = 1.0
    @State private var offset: CGSize = .zero

    var body: some View {
        Text(particle.type.emoji)
            .font(.system(size: 14))
            .opacity(opacity)
            .offset(offset)
            .onAppear {
                withAnimation(.linear(duration: particle.lifetime)) {
                    offset = CGSize(width: particle.velocity.dx * particle.lifetime,
                                    height: particle.velocity.dy * particle.lifetime)
                    opacity = 0
                }
            }
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
