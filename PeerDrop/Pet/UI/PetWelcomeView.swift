import SwiftUI

/// First-open reveal screen shown the first time a user opens the Pet tab in
/// v4.0.1. Replaces the v3.x egg-hatch wait UX: in v4.0.1 pets start at .baby
/// stage immediately, so this gives them a moment of "tada, here's your pet"
/// the first time they visit the tab. Gated by `PetWelcomeFlag`.
///
/// Renders the pet via `PetRendererV3` directly (same pattern as
/// `GuestPetView`) — no dependency on `FloatingPetView`'s physics/state.
struct PetWelcomeView: View {
    let pet: PetState
    let onDismiss: () -> Void

    @State private var revealScale: CGFloat = 0.3
    @State private var revealOpacity: Double = 0
    @State private var celebrationOffset: CGFloat = -20
    @State private var renderedImage: CGImage?
    @State private var renderer = PetRendererV3()

    var body: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()

            VStack(spacing: 24) {
                Text("🎉")
                    .font(.system(size: 64))
                    .offset(y: celebrationOffset)
                    .animation(
                        .easeInOut(duration: 1.4).repeatForever(autoreverses: true),
                        value: celebrationOffset)

                Text("welcome.congrats")
                    .font(.title.bold())
                    .foregroundStyle(.white)

                SpriteImageView(image: renderedImage, displaySize: 200)
                    .scaleEffect(revealScale)
                    .opacity(revealOpacity)
                    .frame(width: 200, height: 200)

                Text(speciesDisplayName)
                    .font(.title2.bold())
                    .foregroundStyle(.white)

                Text("welcome.subtitle")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Button {
                    onDismiss()
                } label: {
                    Text("welcome.cta")
                        .font(.headline)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.8, dampingFraction: 0.6).delay(0.3)) {
                revealScale = 1.0
                revealOpacity = 1
            }
            celebrationOffset = 20
        }
        .task {
            await renderSnapshot()
        }
    }

    /// Family-level species name (e.g. "Cat", "Dog"). Pet has no per-species
    /// localized displayName today, so we capitalize the SpeciesID family — it's
    /// a stable, non-localized identifier and matches the asset family name.
    /// Phase 6 may swap this for localized strings if product wants.
    private var speciesDisplayName: String {
        pet.genome.resolvedSpeciesID.family.capitalized
    }

    @MainActor
    private func renderSnapshot() async {
        renderedImage = try? await renderer.render(
            genome: pet.genome,
            level: pet.level,
            mood: pet.mood,
            direction: .east)
    }
}
