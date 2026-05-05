import Foundation

/// One of the eight rotations that PixelLab generates per sprite. Raw values match
/// the PNG filename slugs inside each species zip (e.g. `rotations/south-east.png`).
enum SpriteDirection: String, CaseIterable, Hashable {
    case south       = "south"
    case southEast   = "south-east"
    case east        = "east"
    case northEast   = "north-east"
    case north       = "north"
    case northWest   = "north-west"
    case west        = "west"
    case southWest   = "south-west"
}

/// Cache key for the M3 sprite pipeline. Identifies one decoded `CGImage` —
/// a single direction frame for one species at one life stage.
///
/// `mood` is intentionally NOT part of the request: per the 2026-04-29 plan
/// pivot (commit 23b3caf), mood is rendered as a runtime overlay icon by M4b,
/// not as a separate PNG zip variant. This keeps the bundle at ~3.7 MB
/// (neutral sprites only) and removes ~1,485 mood-variant generations from
/// the asset gen sprint.
struct SpriteRequest: Hashable {
    let species: SpeciesID
    let stage: PetLevel
    let direction: SpriteDirection
}
