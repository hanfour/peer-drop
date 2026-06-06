import SwiftUI
import PeerDropPet

/// Sidebar "Pet" section — full-size sprite + name/level placeholder.
///
/// Reads `PetEngine.renderedImage` (CGImage?) directly. Sprite stays in
/// sync because the engine republishes `renderedImage` on every animator
/// tick (~12fps default), every interaction, every evolve, and every
/// physics update — see `PetEngine.updateRenderedImage()`.
///
/// Plan deviation: the M2 plan referenced
/// `connectionManager.currentPetSprite` which doesn't exist. PetEngine is
/// a separate @StateObject in PeerDropMacApp; this view consumes it as
/// an @EnvironmentObject (matches the iOS-side pattern).
struct PetSectionView: View {
    @EnvironmentObject var petEngine: PetEngine

    var body: some View {
        VStack(spacing: 24) {
            Text("Your Pet")
                .font(.largeTitle)

            PetSpriteView(size: 256)

            VStack(spacing: 4) {
                // PetState.name is String? (nil until first naming).
                if let name = petEngine.pet.name, !name.isEmpty {
                    Text(name)
                        .font(.headline)
                }
                // PetState exposes `level: PetLevel` (the plan called it
                // `stage`; the actual field is `level`). `displayName`
                // returns the localised stage label ("幼年" / "成熟" /
                // "老年" — already in zh-Hant per the enum source).
                Text(petEngine.pet.level.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 32)
    }
}

/// Reusable sprite view — used by the sidebar Pet section (256pt) and
/// by MenuBarContent's mini-sprite slot (60pt).
///
/// Pixel-perfect rendering via `.interpolation(.none)`: PetEngine
/// renders the v5 multi-frame sprite at the source pixel grid and we
/// must NOT smooth-scale when displaying at integer multiples. The
/// `scaledToFit()` modifier keeps aspect ratio while honouring the
/// outer `.frame(width:height:)`.
struct PetSpriteView: View {
    let size: CGFloat
    @EnvironmentObject var petEngine: PetEngine

    var body: some View {
        Group {
            if let cgImage = petEngine.renderedImage {
                Image(decorative: cgImage, scale: 1.0)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
            } else {
                // First-launch / pre-render placeholder. PetEngine's
                // updateRenderedImage() is async (SpriteService is an
                // actor) so renderedImage stays nil for ~one frame
                // after init.
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.1))
                    .overlay(ProgressView().scaleEffect(0.6))
            }
        }
        .frame(width: size, height: size)
    }
}
