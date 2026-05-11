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
    /// filename is the bare family ID and the same asset is returned for any
    /// requested `stage`. Derived from `SpeciesCatalog.isSingleAssetFamily(_:)`
    /// so atomic multi-stage flips happen in one place. Currently empty — no
    /// shipping family uses single-asset bundling.
    static var singleStageSpecies: Set<SpeciesID> {
        let families = Set(SpeciesCatalog.allIDs.map { $0.family })
        return Set(families
                    .filter { SpeciesCatalog.isSingleAssetFamily($0) }
                    .map { SpeciesID($0) })
    }

    /// Bundle filename (without extension) for the request, after catalog
    /// fallback. Returns nil when no asset filename can be derived — i.e.
    /// the family is unknown to the catalog OR the requested stage isn't
    /// shipped (caller falls back via PetRendererV3.ultimateFallback).
    /// Pure function; no I/O.
    static func filename(for request: SpriteRequest) -> String? {
        guard let resolved = SpeciesCatalog.resolve(request.species) else {
            return nil
        }
        let family = resolved.family

        // Single-asset family: bare family ID, no stage suffix. The same
        // `<family>.zip` is returned for every PetLevel — by design these
        // families ship as one bundled asset.
        if SpeciesCatalog.isSingleAssetFamily(family) {
            return family
        }

        // Stage isn't shipped for this family (e.g. octopus-adult, bird-baby).
        // Return nil so PetRendererV3.ultimateFallback handles the gap.
        let stagesShipped = SpeciesCatalog.stagesShipped(for: family)
        guard stagesShipped.contains(request.stage) else { return nil }

        // Standard species×stage path.
        return "\(resolved.rawValue)-\(request.stage.assetSlug)"
    }

    /// Bundle URL for the request's zip, or nil if it isn't bundled.
    /// Defaults to the main app bundle; tests inject the test bundle.
    static func url(for request: SpriteRequest, in bundle: Bundle = .main) -> URL? {
        guard let name = filename(for: request) else { return nil }
        return bundle.url(forResource: name, withExtension: "zip", subdirectory: bundleSubdirectory)
    }

}
