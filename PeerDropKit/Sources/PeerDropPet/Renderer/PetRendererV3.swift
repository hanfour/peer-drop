import Foundation
import PeerDropPlatform
import CoreGraphics
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
public final class PetRendererV3 {

    private let service: SpriteService

    /// Fallback warnings deduped per (species, stage) — the render loop
    /// runs at animation rate (~6–12 fps), so an unconditional warning for
    /// a partial-coverage species floods the log with hundreds of identical
    /// lines per minute (audit round 15). First occurrence still logs.
    private var loggedMissingAssets = Set<String>()
    private let loggedMissingAssetsLock = NSLock()

    private func logMissingAssetOnce(species: SpeciesID, stage: PetLevel) {
        let key = "\(species.rawValue)#\(stage.rawValue)"
        loggedMissingAssetsLock.lock()
        let firstTime = loggedMissingAssets.insert(key).inserted
        loggedMissingAssetsLock.unlock()
        guard firstTime else { return }
        rendererLogger.warning("Asset missing for species=\(species.rawValue, privacy: .public) stage=\(stage.rawValue); falling back to \(Self.ultimateFallback.rawValue, privacy: .public) (further occurrences suppressed)")
    }

    /// Ultimate fallback species when a pet's resolved SpeciesID has no
    /// shipping assets (e.g. partial-coverage species like `octopus-adult`
    /// or `bird-baby`). The fallback target MUST have all 3 stages bundled —
    /// `cat-tabby` was chosen because it's the legacy `BodyGene.cat` default
    /// and the most coverage-tested asset in the bundle. SpriteService
    /// deliberately keeps the strict `assetNotFound` contract for diagnostic
    /// value; renderer-layer fallback is the right surface to absorb the gap.
    public static let ultimateFallback = SpeciesID("cat-tabby")

    /// Fraction of the base sprite's width consumed by the mood overlay.
    /// 16/68 ≈ 0.235 was chosen visually for the v4.0 PixelLab 68×68 output
    /// (Plan §M4b.2). Encoding the fraction instead of a pixel count keeps the
    /// overlay proportional if M5 ever ships assets at different dimensions
    /// (e.g. a 96×96 hero shot would scale the icon to ~22 px instead of
    /// staying stuck at 16 px and looking lost).
    public static let overlayWidthFraction: CGFloat = 16.0 / 68.0

    /// Resolves the overlay side length for a given base sprite width. Clamped
    /// to [8, 32] so very small / very large hypothetical assets still render
    /// a recognizable SF Symbol — below 8 the glyph stops being legible, above
    /// 32 it dominates the sprite.
    public static func overlaySidePixels(forBaseWidth width: CGFloat) -> CGFloat {
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

    public init(service: SpriteService = .shared) {
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

    public func render(
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
        let composited = composite(basePNG: basePNG, species: species, mood: mood)
        lastComposite = (key, composited)
        return composited
    }

    /// v5 multi-frame entry. Picks `frameIndex` from the action's frame array
    /// (or wraps to 0 if out of bounds) and composites the mood overlay.
    /// Same ultimateFallback species behavior as the v4 entry above.
    /// Doesn't share the `lastComposite` memoization with the v4 entry: the
    /// new key would need to include action+frameIndex, and animator-driven
    /// renders at ~12 Hz mostly hit different frames anyway.
    public func render(
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
        return composite(basePNG: basePNG, species: species, mood: mood)
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
            logMissingAssetOnce(species: species, stage: stage)
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
    /// requested species×stage has no shipping zip. Without this, incomplete
    /// species (e.g. `octopus-adult`, `bird-baby/adult`) would crash the
    /// renderer instead of showing the safe cat-tabby placeholder.
    /// SpriteService deliberately keeps the strict `assetNotFound` contract
    /// (its tests pin it), so the fallback has to live at the renderer layer.
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
            logMissingAssetOnce(species: species, stage: stage)
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
    /// Determinism: PlatformGraphicsRenderer produces byte-identical output for
    /// identical inputs. The M4.3 caching contract (and the lastComposite
    /// memoization above) relies on this — don't substitute a non-deterministic
    /// primitive (e.g. CIContext) without also revisiting those tests.
    private func composite(basePNG: CGImage, species: SpeciesID, mood: PetMood) -> CGImage {
        let size = CGSize(width: basePNG.width, height: basePNG.height)
        let renderer = PlatformGraphicsRenderer(size: size)

        let composited = renderer.image { cgCtx in
            // 1) Base sprite — draw the basePNG via CGContext directly.
            // CoreGraphics's coordinate system is bottom-left origin so we
            // flip the Y axis to match the top-left convention before drawing,
            // matching the prior UIImage(cgImage:).draw(in:) behavior.
            cgCtx.saveGState()
            cgCtx.translateBy(x: 0, y: size.height)
            cgCtx.scaleBy(x: 1, y: -1)
            cgCtx.draw(basePNG, in: CGRect(origin: .zero, size: size))
            cgCtx.restoreGState()

            // 2) Rarity border draws BETWEEN the base sprite and the mood
            // overlay so it sits on the sprite edge but doesn't occlude
            // the mood icon at the top-right. Returns nil for .common
            // tier (no border).
            if let borderColor = RarityOverlay.borderColor(for: species) {
                let width = RarityOverlay.borderWidth(for: species)
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: width / 2, dy: width / 2)
                cgCtx.setStrokeColor(borderColor.cgColor)
                cgCtx.setLineWidth(width)
                cgCtx.stroke(rect)
            }

            // 3) Mood overlay — SF Symbol composited at top-right corner.
            let side = Self.overlaySidePixels(forBaseWidth: size.width)
            let iconRect = CGRect(
                x: size.width - side,
                y: 0,
                width: side,
                height: side
            )
            let iconName = MoodOverlay.iconName(mood)
            let tint = MoodOverlay.tintColor(mood)
            if let icon = PlatformImage(platformSystemName: iconName)?.platformWithTintColor(tint) {
                // Draw via PlatformImage's draw(in:) which respects the
                // current graphics context. UIImage.draw(in:) works on iOS;
                // NSImage.draw(in:) works on macOS — both honor the current
                // graphics context set by PlatformGraphicsRenderer.
                icon.draw(in: iconRect)
            }
        }

        if let cg = composited.platformCGImage {
            return cg
        }
        // PlatformGraphicsRenderer normally produces a CGImage-backed
        // PlatformImage. If it doesn't (some color-space edge cases), the
        // mood overlay vanishes silently — log so the issue is at least visible.
        rendererLogger.warning("PlatformGraphicsRenderer returned PlatformImage with nil cgImage; mood overlay dropped for mood=\(mood.rawValue, privacy: .public)")
        return basePNG
    }
}
