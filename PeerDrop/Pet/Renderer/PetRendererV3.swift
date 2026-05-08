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
    ///
    /// Contract history: M4 review locked `test_render_ghost_throwsAssetNotFound`
    /// with the strict-error contract on the assumption that a nil image was
    /// preferable to a wrong placeholder. M8 phase 5 reversed this — once the
    /// legacy widget path was removed, every consumer needed SOME image to
    /// avoid blank UI on legacy pets, and SpriteService keeps the strict
    /// assetNotFound contract for its own diagnostic value. Renderer-layer
    /// fallback is the right surface to absorb the gap. Tests updated:
    ///   `test_render_ghostBody_fallsBackToUltimatePlaceholder`
    ///   `test_updateRenderedImage_writesPlaceholder_whenSpeciesAssetMissing`
    static let ultimateFallback = SpeciesID("cat-tabby")

    /// Fraction of the base sprite's width consumed by the mood overlay.
    /// 16/68 ≈ 0.235 was chosen visually for the v4.0 PixelLab 68×68 output
    /// (Plan §M4b.2). Encoding the fraction instead of a pixel count keeps the
    /// overlay proportional if M5 ever ships assets at different dimensions
    /// (e.g. a 96×96 hero shot would scale the icon to ~22 px instead of
    /// staying stuck at 16 px and looking lost).
    static let overlayWidthFraction: CGFloat = 16.0 / 68.0

    /// Resolves the overlay side length for a given base sprite width. Clamped
    /// to [8, 32] so very small / very large hypothetical assets still render
    /// a recognizable SF Symbol — below 8 the glyph stops being legible, above
    /// 32 it dominates the sprite.
    static func overlaySidePixels(forBaseWidth width: CGFloat) -> CGFloat {
        let target = (width * overlayWidthFraction).rounded()
        return min(max(target, 8), 32)
    }

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
        #if DEBUG
        // Defensive: if someone refactors the catalog and removes cat-tabby
        // (or sets ultimateFallback to a bogus ID), every legacy pet would
        // fall through to a now-failing fallback and the bug would only show
        // up at first user render. This precondition trips at first init
        // instead.
        precondition(SpeciesCatalog.allIDs.contains(Self.ultimateFallback),
                     "PetRendererV3.ultimateFallback (\(Self.ultimateFallback.rawValue)) must be in SpeciesCatalog")
        #endif
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

    /// v5 multi-frame entry. Picks `frameIndex` from the action's frame array
    /// (or wraps to 0 if out of bounds) and composites the mood overlay.
    /// Same ultimateFallback species behavior as the v4 entry above.
    /// Doesn't share the `lastComposite` memoization with the v4 entry: the
    /// new key would need to include action+frameIndex, and animator-driven
    /// renders at ~12 Hz mostly hit different frames anyway.
    func render(
        genome: PetGenome,
        level: PetLevel,
        direction: SpriteDirection,
        action: PetAction,
        frameIndex: Int,
        mood: PetMood
    ) async throws -> CGImage {
        let species = genome.resolvedSpeciesID
        let basePNG = try await loadAnimationFrame(
            species: species,
            stage: level,
            direction: direction,
            action: action,
            frameIndex: frameIndex
        )
        return composite(basePNG: basePNG, mood: mood)
    }

    private func loadAnimationFrame(
        species: SpeciesID,
        stage: PetLevel,
        direction: SpriteDirection,
        action: PetAction,
        frameIndex: Int
    ) async throws -> CGImage {
        let request = AnimationRequest(species: species, stage: stage, direction: direction, action: action)
        do {
            let frames = try await service.frames(for: request)
            return frames.images[safeIndex(frameIndex, in: frames.images.count)]
        } catch SpriteServiceError.assetNotFound {
            if species == Self.ultimateFallback {
                throw SpriteServiceError.assetNotFound(request.spriteRequest)
            }
            rendererLogger.warning("Asset missing for species=\(species.rawValue, privacy: .public) stage=\(stage.rawValue); falling back to \(Self.ultimateFallback.rawValue, privacy: .public)")
            let fallback = AnimationRequest(
                species: Self.ultimateFallback,
                stage: stage,
                direction: direction,
                action: action
            )
            let frames = try await service.frames(for: fallback)
            return frames.images[safeIndex(frameIndex, in: frames.images.count)]
        }
    }

    private func safeIndex(_ requested: Int, in count: Int) -> Int {
        guard count > 0 else { return 0 }
        return (requested >= 0 && requested < count) ? requested : 0
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

            let side = Self.overlaySidePixels(forBaseWidth: size.width)
            let iconRect = CGRect(
                x: size.width - side,
                y: 0,
                width: side,
                height: side
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
