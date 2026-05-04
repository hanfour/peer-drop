import Foundation
import CoreGraphics
import UIKit
import OSLog

private let rendererLogger = Logger(subsystem: "com.hanfour.peerdrop", category: "PetRendererV3")

/// v4.0 PNG-pipeline pet renderer. Replaces the legacy `PetRendererV2` (which
/// composites palette-swapped UInt8 sprites with eye/pattern overlays).
///
/// Renders flow: PetGenome → SpriteRequest → SpriteService.image → composite
/// mood overlay → CGImage. The mood overlay is an SF Symbol drawn at the
/// top-right of the base PNG (per M4b.2); the icon + tint come from
/// MoodOverlay (M4b.1).
@MainActor
final class PetRendererV3 {

    private let service: SpriteService

    /// Ultimate fallback species when a pet's resolved SpeciesID has no
    /// shipping assets (e.g. legacy `BodyGene.ghost` whose v4.0 assets weren't
    /// generated, or stages where some species are missing entries like
    /// `octopus-adult`). The fallback target MUST have all 3 stages bundled —
    /// `cat-tabby` was chosen because it's the legacy `BodyGene.cat` default
    /// and the most coverage-tested asset in the bundle.
    static let ultimateFallback = SpeciesID("cat-tabby")

    /// Side length of the overlay icon in pixels of the base sprite. Coupled
    /// to the current asset shape (68×68 PixelLab output → 16 px ≈ 23% width).
    /// If M5 ships assets at different dimensions per stage, this constant
    /// will need to be either rescaled relative to the base PNG width or made
    /// per-stage. Plan §M4b.2 specified 16 px, which we honour for v4.0.
    static let overlaySidePixels: CGFloat = 16

    /// Single-entry memoization of the last composite result. Repeated renders
    /// with identical inputs (extremely common — animator ticks at ~12 Hz with
    /// the same direction + mood) skip the UIGraphicsImageRenderer pass.
    private struct CompositeKey: Hashable {
        let species: SpeciesID
        let stage: PetLevel
        let direction: SpriteDirection
        let mood: PetMood
    }
    private var lastComposite: (key: CompositeKey, image: CGImage)?

    init(service: SpriteService = .shared) {
        self.service = service
    }

    func render(
        genome: PetGenome,
        level: PetLevel,
        mood: PetMood,
        direction: SpriteDirection
    ) async throws -> CGImage {
        let species = genome.resolvedSpeciesID
        let key = CompositeKey(species: species, stage: level, direction: direction, mood: mood)
        if let cached = lastComposite, cached.key == key {
            return cached.image
        }

        let basePNG = try await loadBasePNG(species: species, stage: level, direction: direction)
        let composited = composite(basePNG: basePNG, mood: mood)
        lastComposite = (key, composited)
        return composited
    }

    /// Fetches the base sprite, falling back to `ultimateFallback` when the
    /// requested species×stage has no shipping zip. Without this, legacy
    /// `BodyGene.ghost` pets and incomplete species (e.g. `octopus-adult`,
    /// `bird-baby/adult`) would crash the renderer instead of showing the
    /// safe cat-tabby placeholder. SpriteService deliberately keeps the
    /// strict `assetNotFound` contract (its tests pin it), so the fallback
    /// has to live at the renderer layer.
    private func loadBasePNG(
        species: SpeciesID,
        stage: PetLevel,
        direction: SpriteDirection
    ) async throws -> CGImage {
        let request = SpriteRequest(species: species, stage: stage, direction: direction)
        do {
            return try await service.image(for: request)
        } catch SpriteServiceError.assetNotFound {
            if species == Self.ultimateFallback {
                throw SpriteServiceError.assetNotFound(request)
            }
            rendererLogger.warning("Asset missing for species=\(species.rawValue, privacy: .public) stage=\(stage.rawValue); falling back to \(Self.ultimateFallback.rawValue, privacy: .public)")
            let fallbackRequest = SpriteRequest(
                species: Self.ultimateFallback,
                stage: stage,
                direction: direction)
            return try await service.image(for: fallbackRequest)
        }
    }

    /// Draws the mood overlay icon at the top-right corner of the base PNG.
    /// Plan §M4b.2 mentions a "skip if mood == .neutral" path, but PetMood has
    /// no .neutral case — it's always one of the 6 active moods, so the
    /// overlay always renders.
    ///
    /// Determinism: UIGraphicsImageRenderer produces byte-identical output for
    /// identical inputs. The M4.3 caching contract (and the lastComposite
    /// memoization above) relies on this — don't substitute a non-deterministic
    /// primitive (e.g. CIContext) without also revisiting those tests.
    private func composite(basePNG: CGImage, mood: PetMood) -> CGImage {
        let size = CGSize(width: basePNG.width, height: basePNG.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        let composited = renderer.image { _ in
            UIImage(cgImage: basePNG).draw(in: CGRect(origin: .zero, size: size))

            let iconRect = CGRect(
                x: size.width - Self.overlaySidePixels,
                y: 0,
                width: Self.overlaySidePixels,
                height: Self.overlaySidePixels
            )
            let iconName = MoodOverlay.iconName(mood)
            let tint = MoodOverlay.tintColor(mood)
            UIImage(systemName: iconName)?
                .withTintColor(tint, renderingMode: .alwaysOriginal)
                .draw(in: iconRect)
        }

        if let cg = composited.cgImage {
            return cg
        }
        // UIGraphicsImageRenderer.image normally produces a CGImage-backed
        // UIImage. If it doesn't (some color-space edge cases), the mood
        // overlay vanishes silently — log so the issue is at least visible.
        rendererLogger.warning("UIGraphicsImageRenderer returned UIImage with nil cgImage; mood overlay dropped for mood=\(mood.rawValue, privacy: .public)")
        return basePNG
    }
}
