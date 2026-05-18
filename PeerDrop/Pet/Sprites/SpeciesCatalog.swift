import Foundation

// MARK: - Variant traits (Phase V.a, see docs/plans/2026-05-17-variant-traits.md)

/// Collection-tier classification per variant. Affects hatching weights (rarer
/// variants drop less often during egg-hatch) and visual treatment (border /
/// sparkle overlay layered on the sprite at render time). Defaults to `.common`
/// when no rarity trait is assigned to a `VariantSpec`.
enum Rarity: Int, CaseIterable {
    case common = 0
    case rare = 1
    case epic = 2
    case legendary = 3

    /// Hatching weight for the egg-system. Common variants drop ~4× as often
    /// as rare, ~20× as often as epic, ~100× as often as legendary.
    var hatchWeight: Int {
        switch self {
        case .common:    return 100
        case .rare:      return 25
        case .epic:      return 5
        case .legendary: return 1
        }
    }
}

/// Per-variant trait that the runtime reacts to. Lets a variant differ from
/// its family default by more than color/pattern alone — see Phase V plan
/// for the "differentiation hook" rationale.
enum VariantTrait: Hashable {
    /// A decorative overlay PNG composited on top of the base sprite at the
    /// neck/head anchor. Asset name resolves to `Pets/accessories/<name>.png`.
    case accessory(assetName: String)

    /// An extra idle animation (3 frames × 8 directions) played after the
    /// pet has been idle for `triggerSeconds`. Asset is keyed in the species
    /// zip's metadata.json under animations with the supplied key.
    case uniqueIdle(animationKey: String, triggerSeconds: TimeInterval)

    /// Collection rarity. Pure code (no asset) — runtime adds a border +
    /// optional sparkle overlay based on tier.
    case rarity(Rarity)
}

/// Declaration of one variant within a family. The legacy API
/// `SpeciesCatalog.variants(for:)` returns `[String]` constructed from the
/// `id` field for backward compatibility; new code that needs trait info
/// calls `variantSpecs(for:)`.
struct VariantSpec: Hashable {
    let id: String
    let traits: Set<VariantTrait>

    init(_ id: String, traits: Set<VariantTrait> = []) {
        self.id = id
        self.traits = traits
    }

    /// Rarity tier for this variant (defaults to `.common` if no rarity
    /// trait was assigned).
    var rarity: Rarity {
        for t in traits {
            if case .rarity(let r) = t { return r }
        }
        return .common
    }

    /// Accessory asset name, if any. nil for variants without an accessory.
    var accessoryAssetName: String? {
        for t in traits {
            if case .accessory(let name) = t { return name }
        }
        return nil
    }

    /// `(animationKey, triggerSeconds)` for the unique-idle trait, if any.
    var uniqueIdle: (key: String, after: TimeInterval)? {
        for t in traits {
            if case .uniqueIdle(let key, let secs) = t { return (key, secs) }
        }
        return nil
    }
}

/// Registry of every known species in the v4.0 PNG pipeline.
///
/// Data layout: each family maps to an ordered list of sub-variety strings, with
/// the first element treated as the family default. Single-variety legacy families
/// (bird, frog, octopus) carry an empty variants list — their `SpeciesID`
/// is the bare family name.
///
/// **stagesShipped** (added v5.0 review #2): the subset of `PetLevel` values
/// actually present as separate zip files for this family. Two patterns:
///
/// - Multi-variety species with full coverage: `[.baby, .adult, .elder]` —
///   each (variant, stage) combo has its own zip.
/// - Single-variety with partial coverage: e.g. bird/frog/octopus ship a
///   subset (`[.elder]` or `[.baby, .elder]`) — missing stages return nil
///   from SpriteAssetResolver and trigger PetRendererV3.ultimateFallback.
///
/// `bundleAsSingleAsset` survives as plumbing for any future single-asset
/// family (one bare `<family>.zip` covering every PetLevel) but no
/// currently-shipped family uses it.
///
/// Defaults match plan §M2.3 locked picks for legacy BodyGene mappings
/// (cat→tabby, dog→shiba, bear→brown, dragon→western, slime→green,
/// rabbit→dutch). Other families (including totoro, which has no legacy
/// BodyGene case) default to alphabetical first.
///
/// Source of truth: zip filenames under
/// docs/pet-design/ai-brief/species-zips-stages/. If a zip is added or removed
/// during the asset gen sprint, update this table to match.
enum SpeciesCatalog {

    private struct Family {
        /// Ordered: first element is the default sub-variety for this family.
        /// Empty for single-variety legacy families (bird, frog, octopus).
        ///
        /// Phase V.a (2026-05-17): migrated from `[String]` to `[VariantSpec]`
        /// so each variant can carry traits (rarity, accessory, uniqueIdle).
        /// Pre-existing variants migrated to empty-traits `VariantSpec` — no
        /// behavior change for them. New variants can opt in by passing
        /// `traits:` to the initializer.
        let variants: [VariantSpec]

        /// PetLevels for which this family has shipped zip assets. Used by
        /// SpriteAssetResolver to determine which (species, stage) combos
        /// resolve to a bundled zip. Defaults to all 3 stages.
        var stagesShipped: Set<PetLevel> = [.baby, .adult, .elder]

        /// True iff this family ships as ONE bare-family-named zip used at
        /// every PetLevel, regardless of `stagesShipped`. False (default)
        /// means each shipped stage has its own `<species-id>-<stage>.zip`
        /// — that includes partial-coverage single-variety species (e.g.
        /// bird/frog ship as `bird-elder.zip`).
        var bundleAsSingleAsset: Bool = false
    }

    /// Shorthand for the common case where a variant has no traits. Keeps
    /// the families table readable at a glance; new variants with hooks
    /// inline-spell `VariantSpec("name", traits: [.rarity(.rare)])`.
    private static func v(_ id: String) -> VariantSpec { VariantSpec(id) }

    private static let families: [String: Family] = [
        "bear":     Family(variants: [v("brown"), v("black"),
                                       VariantSpec("panda", traits: [.rarity(.rare)]),
                                       VariantSpec("polar", traits: [.rarity(.epic)])]),
        "bird":     Family(variants: [], stagesShipped: [.elder]),                          // partial coverage; bird-elder.zip
        "cat":      Family(variants: [v("tabby"), v("bengal"), v("calico"),
                                       VariantSpec("persian", traits: [.rarity(.rare)]),
                                       VariantSpec("siamese", traits: [.rarity(.rare)])]),
        "cow":      Family(variants: [v("highland"), v("holstein"), v("yellow")]),
        "deer":     Family(variants: [v("moose"), v("sika"), v("whitetail")]),
        "dog":      Family(variants: [v("shiba"),
                                       VariantSpec("collie", traits: [.rarity(.rare)]),
                                       v("dachshund"),
                                       VariantSpec("husky", traits: [.rarity(.rare)]),
                                       v("labrador")]),
        "dragon":   Family(variants: [v("western"), v("eastern"), v("fire"), v("ice")]),
        "duck":     Family(variants: [v("mallard"), v("mandarin"), v("yellow")]),
        "fox":      Family(variants: [v("arctic"), v("red"),
                                       VariantSpec("silver", traits: [.rarity(.epic)])]),
        "frog":     Family(variants: [], stagesShipped: [.elder]),                          // partial coverage; frog-elder.zip
        "hamster":  Family(variants: [v("campbell"), v("golden"), v("white"), v("winterwhite")]),
        "hedgehog": Family(variants: [v("brown"), v("chocolate"), v("white")]),
        "horse":    Family(variants: [v("black"), v("chestnut"), v("zebra")]),
        "lizard":   Family(variants: [v("bearded"), v("chameleon"), v("gecko")]),
        "octopus":  Family(variants: [], stagesShipped: [.baby, .elder]),  // partial coverage
        "otter":    Family(variants: [v("river"), v("sea")]),
        "owl":      Family(variants: [v("barn"), v("horned"), v("snowy")]),
        "parrot":   Family(variants: [v("budgie"), v("cockatiel"), v("macaw")]),
        "penguin":  Family(variants: [v("crested"), v("emperor"), v("king")]),
        "phoenix":  Family(variants: [v("fire"), v("ice"), v("light")]),
        "pig":      Family(variants: [v("black"),
                                       VariantSpec("boar", traits: [.rarity(.epic)]),
                                       v("pink"),
                                       VariantSpec("potbelly", traits: [.rarity(.rare)])]),
        "pigeon":   Family(variants: [v("grey"), v("homing"), v("white")]),
        "rabbit":   Family(variants: [v("dutch"), v("angora"),
                                       VariantSpec("lionhead", traits: [.rarity(.rare)]),
                                       v("lop")]),
        "raccoon":  Family(variants: [v("arctic"), v("standard")]),
        "redpanda": Family(variants: [v("snow"), v("standard")]),
        "sheep":    Family(variants: [v("goat"), v("merino"), v("woolly")]),
        "slime":    Family(variants: [v("green"), v("clear"), v("fire"), v("metal"), v("water")]),
        "sloth":    Family(variants: [v("threetoed"), v("twotoed")]),
        "snake":    Family(variants: [v("ball"), v("corn"), v("milk")]),
        "squirrel": Family(variants: [v("flying"), v("grey"), v("red")]),
        "totoro":   Family(variants: [v("grey"), v("large"), v("mini"), v("white")]),
        "turtle":   Family(variants: [v("sea"), v("tortoise"), v("water")]),
        "unicorn":  Family(variants: [v("dark"), v("rainbow"), v("white")]),
        "wolf":     Family(variants: [v("black"), v("grey"), v("white")]),
    ]

    /// Every valid SpeciesID in the catalog. Multi-variety families contribute one
    /// ID per variant; single-variety families contribute the bare family ID.
    /// Order: family alphabetical, then variant in declared order (default first).
    /// Sorted explicitly because Swift Dictionary iteration order is non-deterministic
    /// across builds — anything that consumes `allIDs[0]` or relies on stable order
    /// (UI species pickers, snapshot tests, asset preflight) needs this guarantee.
    static let allIDs: [SpeciesID] = families.keys.sorted().flatMap { family -> [SpeciesID] in
        let entry = families[family]!
        if entry.variants.isEmpty {
            return [SpeciesID(family)]
        }
        return entry.variants.map { SpeciesID("\(family)-\($0.id)") }
    }

    /// Default SpeciesID for a family. For multi-variety families this is the first
    /// variant (the canonical/legacy default). For single-variety families it's the
    /// bare family ID. Returns nil for unknown families.
    static func familyDefault(for family: String) -> SpeciesID? {
        guard let entry = families[family] else { return nil }
        if let first = entry.variants.first {
            return SpeciesID("\(family)-\(first.id)")
        }
        return SpeciesID(family)
    }

    /// Resolves an ID against the catalog. Returns the input if it's a known ID,
    /// the family default if the family is known but the variant isn't, or nil if
    /// the family is also unknown.
    static func resolve(_ id: SpeciesID) -> SpeciesID? {
        if knownIDSet.contains(id) {
            return id
        }
        return familyDefault(for: id.family)
    }

    private static let knownIDSet: Set<SpeciesID> = Set(allIDs)

    /// Ordered list of sub-variety strings for a family. First element is the
    /// family default. Empty for single-variety legacy families and unknown
    /// families. Returns just the variant IDs — callers that need trait info
    /// (rarity, accessory, uniqueIdle) should use `variantSpecs(for:)`.
    static func variants(for family: String) -> [String] {
        (families[family]?.variants ?? []).map { $0.id }
    }

    /// Full variant specs for a family — same order as `variants(for:)` but
    /// each entry includes the trait set declared in the catalog. Empty for
    /// single-variety legacy families and unknown families.
    static func variantSpecs(for family: String) -> [VariantSpec] {
        families[family]?.variants ?? []
    }

    /// Trait set for a specific SpeciesID, or `[]` if the ID is unknown or
    /// has no traits declared. Resolves the variant by stripping the family
    /// prefix and matching against `variantSpecs(for:)`.
    static func traits(for speciesID: SpeciesID) -> Set<VariantTrait> {
        let family = speciesID.family
        let variantPart = speciesID.rawValue
            .split(separator: "-", maxSplits: 1)
            .dropFirst()
            .joined(separator: "-")
        guard !variantPart.isEmpty else { return [] }
        return variantSpecs(for: family)
            .first(where: { $0.id == variantPart })?
            .traits ?? []
    }

    /// PetLevels with shipped zip assets for a family. Returns full
    /// `[.baby, .adult, .elder]` set for unknown families (defensive fallback).
    static func stagesShipped(for family: String) -> Set<PetLevel> {
        families[family]?.stagesShipped ?? [.baby, .adult, .elder]
    }

    /// True iff this family ships as ONE bare-family-named zip (e.g. `ghost.zip`)
    /// used at every PetLevel. Replaces the old
    /// `SpriteAssetResolver.singleStageSpecies` hardcoded set.
    /// Distinct from "single-variety with partial coverage" (e.g. bird ships
    /// as `bird-elder.zip`, NOT `bird.zip`) — that's
    /// `variants.isEmpty && !bundleAsSingleAsset`.
    static func isSingleAssetFamily(_ family: String) -> Bool {
        families[family]?.bundleAsSingleAsset ?? false
    }
}
