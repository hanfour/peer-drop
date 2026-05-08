import Foundation

/// Maps a `SpriteRequest` to a bundled zip URL.
///
/// Filename convention: `<species-id>-<stage>.zip` under the `Pets/`
/// subdirectory of the host bundle (e.g. `Pets/cat-tabby-adult.zip`).
/// Matches the source layout under
/// `docs/pet-design/ai-brief/species-zips-stages/`. The Pets/ subdirectory
/// comes from XcodeGen's folder-reference inclusion (one PBX entry instead
/// of 324), so additions during the asset gen sprint don't bloat pbxproj.
///
/// Direction is NOT part of the filename — each zip carries all 8 rotations
/// (`rotations/<direction>.png`), decoded by M3.3 SpriteDecoder.
///
/// Fallback: if the requested SpeciesID isn't in the catalog, falls back to
/// the family default (e.g. `cat-imaginary` → `cat-tabby`). No fallback across
/// stages — a missing-stage zip returns nil.
enum SpriteAssetResolver {

    /// Bundle subdirectory holding the species×stage zips. Matches the M5.1
    /// folder-reference layout (`PeerDrop/Resources/Pets/` → `bundle/Pets/`).
    static let bundleSubdirectory = "Pets"

    /// Species shipped as a single zip with no per-stage variants. The bundle
    /// filename is the bare family ID (e.g. `ghost.zip`) and the same asset is
    /// returned for any requested `stage` — they have no baby/adult/elder art.
    ///
    /// Ghost is the v4.0.2 entry: a legacy `BodyGene.ghost` carryover from the
    /// pre-PNG pipeline. The art is a static "Pac-Man ghost" sprite with no
    /// lifecycle progression by design (per docs/pet-design/ai-brief/STATUS.md),
    /// so generating empty baby/elder variants would be busywork. Add new
    /// single-stage species here AND to `SpeciesCatalog.families` together.
    static let singleStageSpecies: Set<SpeciesID> = [SpeciesID("ghost")]

    /// Bundle filename (without extension) for the request, after catalog
    /// fallback. Returns nil when no asset filename can be derived — i.e.
    /// the family is unknown to the catalog. Pure function; no I/O.
    static func filename(for request: SpriteRequest) -> String? {
        guard let resolved = SpeciesCatalog.resolve(request.species) else {
            return nil
        }
        // Single-stage species (ghost, etc.): bare family ID, no stage suffix.
        // The same `<id>.zip` is returned for every PetLevel — these species
        // intentionally have no baby/adult/elder progression, so the
        // species-stage template doesn't apply.
        if singleStageSpecies.contains(resolved) {
            return resolved.rawValue
        }
        return "\(resolved.rawValue)-\(request.stage.assetSlug)"
    }

    /// Bundle URL for the request's zip, or nil if it isn't bundled.
    /// Defaults to the main app bundle; tests inject the test bundle.
    static func url(for request: SpriteRequest, in bundle: Bundle = .main) -> URL? {
        guard let name = filename(for: request) else { return nil }
        return bundle.url(forResource: name, withExtension: "zip", subdirectory: bundleSubdirectory)
    }

}
