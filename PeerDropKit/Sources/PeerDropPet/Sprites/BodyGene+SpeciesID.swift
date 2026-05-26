import Foundation

/// Maps the legacy 9-case BodyGene enum to the v4.0 flat-string SpeciesID.
///
/// Each BodyGene maps to its canonical default sub-variety per plan §M2.3.
/// Per-pet overrides come from PetGenome.subVariety (added in M2.4) — this
/// extension only supplies the family-level default used at migration time.
///
/// Single-variety legacy families (bird, frog, octopus) map to the bare
/// family ID.
extension BodyGene {
    public var defaultSpeciesID: SpeciesID {
        switch self {
        case .cat:     return SpeciesID("cat-tabby")
        case .dog:     return SpeciesID("dog-shiba")
        case .rabbit:  return SpeciesID("rabbit-dutch")
        case .bird:    return SpeciesID("bird")
        case .frog:    return SpeciesID("frog")
        case .bear:    return SpeciesID("bear-brown")
        case .dragon:  return SpeciesID("dragon-western")
        case .octopus: return SpeciesID("octopus")
        case .slime:   return SpeciesID("slime-green")
        }
    }
}

extension PetGenome {
    /// Resolves the v4.0 SpeciesID for this pet using the priority chain:
    ///   1. `subVariety` pinned → use it directly (`body-subVariety`)
    ///   2. `seed` set + family has variants → weighted pick by rarity
    ///   3. fallback → `body.defaultSpeciesID`
    ///
    /// Phase V.b (2026-05-17): seed-driven variant selection now respects
    /// `Rarity.hatchWeight` so tagged variants (e.g. `cat-siamese` rare,
    /// `pig-boar` epic) drop less often than common siblings. Already-
    /// pinned pets (case 1) are unaffected — they keep their `subVariety`
    /// across launches. New hatches and re-resolved pets without pinned
    /// subVariety pick from the weighted distribution.
    public var resolvedSpeciesID: SpeciesID {
        let family = body.rawValue

        if let subVariety = subVariety {
            return SpeciesID("\(family)-\(subVariety)")
        }

        if let seed = seed {
            let specs = SpeciesCatalog.variantSpecs(for: family)
            if !specs.isEmpty {
                return SpeciesID("\(family)-\(weightedPick(specs: specs, seed: seed).id)")
            }
            // Single-variety legacy family (bird/frog/octopus): the bare family
            // ID is the only option.
            return SpeciesID(family)
        }

        return body.defaultSpeciesID
    }

    /// Weighted deterministic variant pick by `Rarity.hatchWeight`. Each
    /// variant occupies a slice of [0, totalWeight); `seed % totalWeight`
    /// lands in exactly one slice. Equivalent to the old uniform `seed %
    /// count` when every variant has the same weight (e.g. all `.common`).
    private func weightedPick(specs: [VariantSpec], seed: UInt32) -> VariantSpec {
        let totalWeight = specs.reduce(0) { $0 + $1.rarity.hatchWeight }
        // Defensive: if every variant somehow has 0 weight, fall back to
        // uniform selection so we never crash.
        guard totalWeight > 0 else {
            return specs[Int(seed % UInt32(specs.count))]
        }
        var pick = Int(seed % UInt32(totalWeight))
        for spec in specs {
            pick -= spec.rarity.hatchWeight
            if pick < 0 {
                return spec
            }
        }
        // Unreachable given the loop's invariant, but the compiler needs an
        // exhaustive return. Pick the last spec as a sentinel.
        return specs.last!
    }
}
