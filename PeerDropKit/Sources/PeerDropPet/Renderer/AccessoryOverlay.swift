import Foundation
import PeerDropPlatform

/// Per-variant decorative accessory overlay (Phase V hook A — see
/// docs/plans/2026-05-17-variant-traits.md).
///
/// Reuses the `MoodOverlay` design pattern: a small PlatformImage composited at
/// render time on top of the base sprite, anchored to a fixed position
/// (neck/head) regardless of facing direction. Cheaper than baking the
/// accessory into the species zip — one asset per variant instead of one
/// per (variant × direction × frame).
///
/// Phase V.a (current): stub — `image(for:)` returns nil for every variant
/// until accessories are designed. PetRendererV3 should call this and
/// no-op when nil.
///
/// Phase V.c (June 17+): seed with `cat-russianblue` → "bow_blue.png" once
/// the asset is in `Resources/Pets/accessories/`. Add ID-to-asset mapping
/// table here.
public enum AccessoryOverlay {

    /// Returns the accessory image for the given species ID, or nil if no
    /// accessory trait is declared (or the asset is missing).
    /// Default is `.module`: accessory PNGs ship inside PeerDropPet's
    /// resource bundle (`Resources/Pets/accessories/`), not the app
    /// bundle — `.main` was a leftover from the pre-SPM layout.
    public static func image(for speciesID: SpeciesID, in bundle: Bundle = SpriteAssetResolver.moduleBundle) -> PlatformImage? {
        guard let assetName = assetName(for: speciesID) else { return nil }
        // Phase V.c: load from bundle path Pets/accessories/<assetName>.png
        // For now stub returns nil since no accessories ship yet.
        _ = assetName
        _ = bundle
        return nil
    }

    /// Resolves the accessory asset name from the variant's traits in
    /// `SpeciesCatalog`. Returns nil for variants without an `.accessory`
    /// trait. Exposed for testability — callers should usually use `image(for:)`.
    public static func assetName(for speciesID: SpeciesID) -> String? {
        for trait in SpeciesCatalog.traits(for: speciesID) {
            if case .accessory(let name) = trait { return name }
        }
        return nil
    }

    /// Pixel anchor for compositing the accessory onto a 68×68 sprite frame.
    /// Coordinates are top-left origin. Phase V.a uses
    /// a single fixed anchor — Phase V.c may vary per species (head height
    /// differs across families).
    public static var defaultAnchor: CGPoint { CGPoint(x: 34, y: 22) }
}
