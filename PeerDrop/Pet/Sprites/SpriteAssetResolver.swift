import Foundation

/// Maps a `SpriteRequest` to a bundled zip URL.
///
/// Filename convention: `<species-id>-<stage>.zip` flat at the bundle root
/// (e.g. `cat-tabby-adult.zip`, `octopus-baby.zip`). Matches the existing
/// shape under `docs/pet-design/ai-brief/species-zips-stages/`, which lets
/// M5 ship the asset bundle by copying zips flat with no renaming.
///
/// Direction is NOT part of the filename — each zip carries all 8 rotations
/// (`rotations/<direction>.png`), decoded by M3.3 SpriteDecoder.
///
/// Fallback: if the requested SpeciesID isn't in the catalog, falls back to
/// the family default (e.g. `cat-imaginary` → `cat-tabby`). No fallback across
/// stages — a missing-stage zip returns nil.
enum SpriteAssetResolver {

    /// Bundle filename (without extension) for the request, after catalog
    /// fallback. Returns nil when no asset filename can be derived — i.e.
    /// the family is unknown to the catalog (egg requests always succeed
    /// because they bypass species lookup). Pure function; no I/O.
    static func filename(for request: SpriteRequest) -> String? {
        // Eggs are visually species-independent (legacy renderer used a single
        // EggSpriteData asset for all pets). Return a global filename so M5
        // bundling can ship one egg.zip rather than 100+ species-egg variants.
        if request.stage == .egg {
            return "egg"
        }
        guard let resolved = SpeciesCatalog.resolve(request.species) else {
            return nil
        }
        return "\(resolved.rawValue)-\(stageSlug(for: request.stage))"
    }

    /// Bundle URL for the request's zip, or nil if it isn't bundled.
    /// Defaults to the main app bundle; tests inject the test bundle.
    static func url(for request: SpriteRequest, in bundle: Bundle = .main) -> URL? {
        guard let name = filename(for: request) else { return nil }
        return bundle.url(forResource: name, withExtension: "zip")
    }

    private static func stageSlug(for stage: PetLevel) -> String {
        switch stage {
        case .egg:   return "egg"   // unreachable via filename() — handled above
        case .baby:  return "baby"
        case .adult: return "adult"
        case .elder: return "elder"
        }
    }
}
