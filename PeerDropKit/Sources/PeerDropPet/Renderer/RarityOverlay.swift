import Foundation
import PeerDropPlatform
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
public enum RarityOverlay {

    /// Border color for the given species ID, or nil if rarity is `.common`
    /// (no border drawn) or no rarity trait is declared.
    public static func borderColor(for speciesID: SpeciesID) -> PlatformColor? {
        switch rarity(for: speciesID) {
        case .common:    return nil
        case .rare:      return rareSilver          // subtle silver
        case .epic:      return epicPurple
        case .legendary: return legendaryGold       // warm gold
        }
    }

    /// Silver border for rare variants. UIColor.systemGray3 on iOS;
    /// fallback RGB on macOS (NSColor has no systemGray3).
    private static var rareSilver: PlatformColor {
        #if canImport(UIKit)
        return .systemGray3
        #else
        return PlatformColor(red: 0.78, green: 0.78, blue: 0.80, alpha: 1)
        #endif
    }

    private static var epicPurple: PlatformColor {
        #if canImport(UIKit)
        return .systemPurple
        #else
        return PlatformColor(red: 0.69, green: 0.32, blue: 0.87, alpha: 1)
        #endif
    }

    private static var legendaryGold: PlatformColor {
        #if canImport(UIKit)
        return .systemYellow
        #else
        return PlatformColor(red: 1.0, green: 0.80, blue: 0.0, alpha: 1)
        #endif
    }

    /// Border thickness in points. Scales with rarity tier — legendary draws
    /// a slightly thicker frame so the tag reads at a glance even at icon
    /// scale.
    public static func borderWidth(for speciesID: SpeciesID) -> CGFloat {
        switch rarity(for: speciesID) {
        case .common:    return 0
        case .rare:      return 1
        case .epic:      return 1.5
        case .legendary: return 2
        }
    }

    /// True iff this variant should render a sparkle particle overlay
    /// (epic and legendary tiers only).
    public static func showsSparkle(for speciesID: SpeciesID) -> Bool {
        switch rarity(for: speciesID) {
        case .common, .rare:      return false
        case .epic, .legendary:   return true
        }
    }

    /// Resolves the rarity tier for a species ID from its variant traits.
    /// Defaults to `.common` if no rarity trait is declared or the species
    /// is unknown.
    public static func rarity(for speciesID: SpeciesID) -> Rarity {
        for trait in SpeciesCatalog.traits(for: speciesID) {
            if case .rarity(let r) = trait { return r }
        }
        return .common
    }
}
