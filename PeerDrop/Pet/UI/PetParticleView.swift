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
