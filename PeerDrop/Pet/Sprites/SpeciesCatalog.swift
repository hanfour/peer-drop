import Foundation

/// Registry of every known species in the v4.0 PNG pipeline.
///
/// Data layout: each family maps to an ordered list of sub-variety strings, with
/// the first element treated as the family default. Single-variety legacy families
/// (bird, frog, octopus) carry an empty variants list — their `SpeciesID` is the
/// bare family name.
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
        let variants: [String]
    }

    private static let families: [String: Family] = [
        "bear":     Family(variants: ["brown", "black", "panda", "polar"]),
        "bird":     Family(variants: []),
        "cat":      Family(variants: ["tabby", "bengal", "calico", "persian", "siamese"]),
        "cow":      Family(variants: ["highland", "holstein", "yellow"]),
        "deer":     Family(variants: ["moose", "sika", "whitetail"]),
        "dog":      Family(variants: ["shiba", "collie", "dachshund", "husky", "labrador"]),
        "dragon":   Family(variants: ["western", "eastern", "fire", "ice"]),
        "duck":     Family(variants: ["mallard", "mandarin", "yellow"]),
        "fox":      Family(variants: ["arctic", "red", "silver"]),
        "frog":     Family(variants: []),
        "hamster":  Family(variants: ["campbell", "golden", "white", "winterwhite"]),
        "hedgehog": Family(variants: ["brown", "chocolate", "white"]),
        "horse":    Family(variants: ["black", "chestnut", "zebra"]),
        "lizard":   Family(variants: ["bearded", "chameleon", "gecko"]),
        "octopus":  Family(variants: []),
        "otter":    Family(variants: ["river", "sea"]),
        "owl":      Family(variants: ["barn", "horned", "snowy"]),
        "parrot":   Family(variants: ["budgie", "cockatiel", "macaw"]),
        "penguin":  Family(variants: ["crested", "emperor", "king"]),
        "phoenix":  Family(variants: ["fire", "ice", "light"]),
        "pig":      Family(variants: ["black", "boar", "pink", "potbelly"]),
        "pigeon":   Family(variants: ["grey", "homing", "white"]),
        "rabbit":   Family(variants: ["dutch", "angora", "lionhead", "lop"]),
        "raccoon":  Family(variants: ["arctic", "standard"]),
        "redpanda": Family(variants: ["snow", "standard"]),
        "sheep":    Family(variants: ["goat", "merino", "woolly"]),
        "slime":    Family(variants: ["green", "clear", "fire", "metal", "water"]),
        "sloth":    Family(variants: ["threetoed", "twotoed"]),
        "snake":    Family(variants: ["ball", "corn", "milk"]),
        "squirrel": Family(variants: ["flying", "grey", "red"]),
        "totoro":   Family(variants: ["grey", "large", "mini", "white"]),
        "turtle":   Family(variants: ["sea", "tortoise", "water"]),
        "unicorn":  Family(variants: ["dark", "rainbow", "white"]),
        "wolf":     Family(variants: ["black", "grey", "white"]),
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
        return entry.variants.map { SpeciesID("\(family)-\($0)") }
    }

    /// Default SpeciesID for a family. For multi-variety families this is the first
    /// variant (the canonical/legacy default). For single-variety families it's the
    /// bare family ID. Returns nil for unknown families.
    static func familyDefault(for family: String) -> SpeciesID? {
        guard let entry = families[family] else { return nil }
        if let first = entry.variants.first {
            return SpeciesID("\(family)-\(first)")
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
    /// families.
    static func variants(for family: String) -> [String] {
        families[family]?.variants ?? []
    }
}
