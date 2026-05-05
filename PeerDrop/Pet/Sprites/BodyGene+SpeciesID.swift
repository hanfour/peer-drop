import Foundation

/// Maps the legacy 10-case BodyGene enum to the v4.0 flat-string SpeciesID.
///
/// Each BodyGene maps to its canonical default sub-variety per plan §M2.3.
/// Per-pet overrides come from PetGenome.subVariety (added in M2.4) — this
/// extension only supplies the family-level default used at migration time.
///
/// Single-variety legacy families (bird, frog, octopus) map to the bare
/// family ID. Ghost has no v4.0 assets and maps to SpeciesID("ghost") which
/// won't resolve in SpeciesCatalog — the M3 loader applies the ultimate
/// fallback in that case.
extension BodyGene {
    var defaultSpeciesID: SpeciesID {
        switch self {
        case .cat:     return SpeciesID("cat-tabby")
        case .dog:     return SpeciesID("dog-shiba")
        case .rabbit:  return SpeciesID("rabbit-dutch")
        case .bird:    return SpeciesID("bird")
        case .frog:    return SpeciesID("frog")
        case .bear:    return SpeciesID("bear-brown")
        case .dragon:  return SpeciesID("dragon-western")
        case .octopus: return SpeciesID("octopus")
        case .ghost:   return SpeciesID("ghost")
        case .slime:   return SpeciesID("slime-green")
        }
    }
}

extension PetGenome {
    /// Resolves the v4.0 SpeciesID for this pet using the priority chain:
    ///   1. `subVariety` pinned → use it directly (`body-subVariety`)
    ///   2. `seed` set + family has variants → deterministic pick by `seed % count`
    ///   3. fallback → `body.defaultSpeciesID`
    var resolvedSpeciesID: SpeciesID {
        let family = body.rawValue

        if let subVariety = subVariety {
            return SpeciesID("\(family)-\(subVariety)")
        }

        if let seed = seed {
            let variants = SpeciesCatalog.variants(for: family)
            if !variants.isEmpty {
                let index = Int(seed % UInt32(variants.count))
                return SpeciesID("\(family)-\(variants[index])")
            }
            // Single-variety legacy family (bird/frog/octopus): the bare family
            // ID is the only option. Returning it here directly rather than
            // falling through to `body.defaultSpeciesID` makes the contract
            // explicit and decouples this branch from the BodyGene mapping table.
            return SpeciesID(family)
        }

        return body.defaultSpeciesID
    }
}
