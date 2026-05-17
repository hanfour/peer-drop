# Variant Traits — Phase V (variant differentiation hooks)

## Strategic context

v5.3.3 (live 2026-05-17) ships animation data for 92 species×stage zips across 7 families (cat, dog, bear, fox, pig, rabbit, hamster). Bundle v5 coverage is 28.4%; the remaining 232 species×stage cells take ~3 months of PixelLab Apprentice quota to fill.

Strategic pivot (2026-05-17 conversation): **stop adding new families, focus on adding new variants within existing families**. Each new variant should differentiate from the base via a "hook" beyond color/pattern, or it'll feel like reskin filler. The 22 families × 3-5 variants existing structure is already collection-shaped; depth here pays off more than another 9 species in `cow`.

## What's a "trait"?

A variant trait is a property declared on a specific variant in `SpeciesCatalog.swift` that the runtime reacts to. Three trait types in this phase:

### A. `accessory` — visual modifier (small overlay PNG)

A decorative accessory rendered on top of the sprite (bow, bandana, hat). Reuses the `MoodOverlay` pattern (UIImage composited at render time). One small PNG per accessory, anchored to a fixed sprite position (head, neck) regardless of direction/frame.

**Cost:** Hand-design 32×32 accessory PNG per variant, ~0 API.

**Concrete example:** `cat-russianblue` wears a small blue bow at the neck position.

### B. `uniqueIdle` — extra idle animation

After N seconds of no user interaction, the standard 3-frame idle loop yields to a unique 3-frame sequence specific to this variant (stretch, sit, sleep, etc.). After the unique sequence completes, returns to standard idle.

**Cost:** 24 frames per variant (3 frames × 8 directions) = 1 PixelLab batch = 24 API calls. Source PNGs go in zip under `animations/<uuid>/<direction>/frame_NNN.png` like the existing idle/walk slots.

**Concrete example:** `cat-mainecoon` stretches every 30s of idle. `dog-shiba` sits down. `rabbit-lop` rolls.

### C. `rarity` — collection tier

A tier (common / rare / epic / legendary) that:
1. Affects hatching weight (rare variants drop less often during egg-hatch)
2. Adds a visual tag (gold/silver/colored border + optional sparkle particle) at render time

**Cost:** Zero new assets — pure code. Rendering reuses `MoodOverlay` SF Symbol pattern with a border treatment.

**Concrete example:** `cat-sphynx` = epic rarity, has a subtle purple border + occasional sparkle particle. Drop weight 1/4 of common.

## Data model

```swift
// SpeciesCatalog.swift (revised)

enum Rarity: Int, CaseIterable {
    case common = 0        // weight 100, no tag
    case rare = 1          // weight 25,  silver border
    case epic = 2          // weight 5,   purple border + sparkle
    case legendary = 3     // weight 1,   gold border + sparkle + halo
}

enum VariantTrait: Hashable {
    case accessory(assetName: String)
    case uniqueIdle(animationKey: String, triggerSeconds: TimeInterval)
    case rarity(Rarity)
}

struct VariantSpec: Hashable {
    let id: String
    let traits: Set<VariantTrait>

    /// Convenience: get rarity (defaults to .common if no rarity trait set).
    var rarity: Rarity {
        for t in traits {
            if case .rarity(let r) = t { return r }
        }
        return .common
    }
}
```

The existing `Family.variants: [String]` migrates to `[VariantSpec]`. All current variants get `VariantSpec(id: "...", traits: [])` — zero behavior change for existing breeds.

## Code touchpoints

| File | Change |
|---|---|
| `SpeciesCatalog.swift` | Variant list type changes; `variants(for:)` returns String array as before; new `variantSpecs(for:)` returns `[VariantSpec]` |
| `BodyGene+SpeciesID.swift` | Optionally use rarity weights in seed selection (Phase V.b) |
| `Sprites/AccessoryOverlay.swift` (new) | `MoodOverlay`-shaped helper for accessory lookup |
| `Sprites/RarityOverlay.swift` (new) | Border / sparkle helper |
| `PetRendererV3` | Layer accessory + rarity overlay during render |
| `SpriteService` | Trigger uniqueIdle animation after N seconds idle |
| `Resources/Pets/accessories/` (new dir) | Accessory PNGs go here |

## Phase rollout

1. **Phase V.a (this commit, no assets):** Data model + Swift API. Existing variants migrate to empty-traits `VariantSpec`. Tests verify SpeciesCatalog still resolves all `allIDs`. **No user-visible change yet.**

2. **Phase V.b (next, no API):** Rarity rendering. Pick 2-3 existing variants and assign `rarity: .rare` to verify border + drop weight work. e.g. `cat-bengal` → rare, `dog-husky` → rare. Already-hatched pets keep their rarity; new hatches use the weight.

3. **Phase V.c (June 17, +API quota):** Add first NEW variant with full hook. Run PixelLab `/create-image-pixflux` to generate 8 rotations for the new breed, then mass-gen pipeline for walk/idle. Hand-design 1 accessory PNG.

4. **Phase V.d:** uniqueIdle animation. Picks a variant from V.c, runs extra mass-gen batch for stretch/sit/sleep frames. SpriteService schedules trigger after configurable idle timeout.

## Phase V.a today's deliverable

1. `SpeciesCatalog.swift` migrated to `VariantSpec` internally; `variants(for:)` still returns `[String]` (call sites unchanged).
2. New types: `Rarity`, `VariantTrait`, `VariantSpec` in same file (or extracted).
3. Empty stubs for `AccessoryOverlay.swift` and `RarityOverlay.swift` — they exist with TODOs but don't render anything yet.
4. New `SpeciesCatalog.variantSpecs(for:)` API returning the new typed list.
5. Unit tests: existing `MainBundleAssetCoverageTests` keeps passing.

## Non-goals for Phase V.a

- No rendering changes — overlays are stubbed, not wired.
- No PixelLab API calls — quota is gone for May.
- No new variants — just rearranging the cabinetry for when June quota refills.
- No behavior changes — pets behave identically to v5.3.3 until V.b adds rendering.

## Tests

Existing tests should keep passing:
- `MainBundleAssetCoverageTests.test_mainBundle_v5Coverage_matchesWhitelist`
- `BodyGene+SpeciesID` selection tests (seed → variant ID)

New tests for V.a:
- `SpeciesCatalogTraitTests` — verify default empty-traits migration didn't drop variants
- `VariantSpecTests` — rarity defaulting, hashable equality
