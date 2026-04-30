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
