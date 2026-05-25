import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Per-variant collection-tier overlay (Phase V hook C — see
/// docs/plans/2026-05-17-variant-traits.md).
///
/// Pure code rendering — no PNG assets. Adds a colored border around the
/// sprite frame and (for epic+) an occasional sparkle particle. Reuses
/// `MoodOverlay`'s SF Symbol pattern where helpful.
///
/// Phase V.a (current): stub — `borderColor(for:)` returns nil for every
/// variant since none have been tagged with a rarity trait yet. PetRendererV3
/// should call this and skip the border draw when nil.
///
/// Phase V.b (next): tag 2-3 existing variants (e.g. `cat-bengal` → .rare,
/// `dog-husky` → .rare) and verify the border renders in Simulator.
enum RarityOverlay {

    /// Border color for the given species ID, or nil if rarity is `.common`
    /// (no border drawn) or no rarity trait is declared.
    static func borderColor(for speciesID: SpeciesID) -> PlatformColor? {
        switch rarity(for: speciesID) {
        case .common:    return nil
        case .rare:      return .systemGray3       // subtle silver
        case .epic:      return .systemPurple
        case .legendary: return .systemYellow      // warm gold
        }
    }

    /// Border thickness in points. Scales with rarity tier — legendary draws
    /// a slightly thicker frame so the tag reads at a glance even at icon
    /// scale.
    static func borderWidth(for speciesID: SpeciesID) -> CGFloat {
        switch rarity(for: speciesID) {
        case .common:    return 0
        case .rare:      return 1
        case .epic:      return 1.5
        case .legendary: return 2
        }
    }

    /// True iff this variant should render a sparkle particle overlay
    /// (epic and legendary tiers only).
    static func showsSparkle(for speciesID: SpeciesID) -> Bool {
        switch rarity(for: speciesID) {
        case .common, .rare:      return false
        case .epic, .legendary:   return true
        }
    }

    /// Resolves the rarity tier for a species ID from its variant traits.
    /// Defaults to `.common` if no rarity trait is declared or the species
    /// is unknown.
    static func rarity(for speciesID: SpeciesID) -> Rarity {
        for trait in SpeciesCatalog.traits(for: speciesID) {
            if case .rarity(let r) = trait { return r }
        }
        return .common
    }
}
