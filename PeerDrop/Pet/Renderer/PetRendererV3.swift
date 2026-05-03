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

        let request = SpriteRequest(species: species, stage: level, direction: direction)
        let basePNG = try await service.image(for: request)
        let composited = composite(basePNG: basePNG, mood: mood)
        lastComposite = (key, composited)
        return composited
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
