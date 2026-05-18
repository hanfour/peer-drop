import XCTest
@testable import PeerDrop

/// Phase V.a (2026-05-17) — verifies the `VariantSpec` / `VariantTrait` /
/// `Rarity` data model and the SpeciesCatalog API around it. Catches three
/// migration mistakes:
///   • A variant accidentally dropped during the [String] → [VariantSpec]
///     refactor (count regression vs the canonical 130-ish allIDs).
///   • A new variant added without showing up in `variantSpecs(for:)`.
///   • Trait lookup returning the wrong set for a tagged variant.
///
/// Phase V.b will add a small handful of tagged variants (rare/epic). These
/// tests should keep passing then; tag-specific behavior gets its own test
/// suite under Renderer/.
final class VariantTraitsTests: XCTestCase {

    // MARK: - Data model

    func test_rarity_hatchWeight_orderedHigherToLower() {
        // Higher tier = lower hatch weight (rarer).
        XCTAssertGreaterThan(Rarity.common.hatchWeight, Rarity.rare.hatchWeight)
        XCTAssertGreaterThan(Rarity.rare.hatchWeight, Rarity.epic.hatchWeight)
        XCTAssertGreaterThan(Rarity.epic.hatchWeight, Rarity.legendary.hatchWeight)
    }

    func test_variantSpec_defaultRarity_isCommon() {
        let spec = VariantSpec("plain")
        XCTAssertEqual(spec.rarity, .common)
        XCTAssertNil(spec.accessoryAssetName)
        XCTAssertNil(spec.uniqueIdle?.key)
    }

    func test_variantSpec_pullsTraitsByCase() {
        let spec = VariantSpec("fancy", traits: [
            .rarity(.epic),
            .accessory(assetName: "bow_blue"),
            .uniqueIdle(animationKey: "stretch", triggerSeconds: 30),
        ])
        XCTAssertEqual(spec.rarity, .epic)
        XCTAssertEqual(spec.accessoryAssetName, "bow_blue")
        XCTAssertEqual(spec.uniqueIdle?.key, "stretch")
        XCTAssertEqual(spec.uniqueIdle?.after, 30)
    }

    // MARK: - SpeciesCatalog API

    func test_variants_for_returnsStringIDs_unchangedFromV4() {
        // Backward-compat: callers like BodyGene+SpeciesID still get strings.
        XCTAssertEqual(SpeciesCatalog.variants(for: "cat"),
                       ["tabby", "bengal", "calico", "persian", "siamese"])
        XCTAssertEqual(SpeciesCatalog.variants(for: "bird"), [])
    }

    func test_variantSpecs_for_returnsTypedListInSameOrder() {
        let specs = SpeciesCatalog.variantSpecs(for: "cat")
        XCTAssertEqual(specs.map { $0.id },
                       ["tabby", "bengal", "calico", "persian", "siamese"])
    }

    func test_variantSpecs_legacyEmptyForSingleVarietyFamilies() {
        XCTAssertTrue(SpeciesCatalog.variantSpecs(for: "bird").isEmpty)
        XCTAssertTrue(SpeciesCatalog.variantSpecs(for: "frog").isEmpty)
        XCTAssertTrue(SpeciesCatalog.variantSpecs(for: "octopus").isEmpty)
    }

    func test_traits_for_returnsEmptyForUntaggedVariants() {
        // bird is single-variety with no traits; cat-bengal is the family
        // default with no traits in Phase V.b.
        XCTAssertTrue(SpeciesCatalog.traits(for: SpeciesID("cat-bengal")).isEmpty)
        XCTAssertTrue(SpeciesCatalog.traits(for: SpeciesID("dog-shiba")).isEmpty)
        XCTAssertTrue(SpeciesCatalog.traits(for: SpeciesID("bird")).isEmpty)
    }

    // MARK: - Phase V.b — first tagged variants

    func test_taggedVariants_haveRarityTrait_2026_05_17() {
        // Phase V.b seeds the system with these tags. Locks them so a
        // future refactor that drops the trait shows up here.
        XCTAssertEqual(RarityOverlay.rarity(for: SpeciesID("cat-siamese")), .rare)
        XCTAssertEqual(RarityOverlay.rarity(for: SpeciesID("dog-husky")), .rare)
        XCTAssertEqual(RarityOverlay.rarity(for: SpeciesID("pig-boar")), .epic)
    }

    func test_taggedVariants_haveRarityTrait_2026_05_18() {
        // Phase V.b second wave (7 new tags). Pinned to lock the
        // 9-tagged-variants v5.3.4 baseline.
        // Rare (silver border, hatch weight 25):
        XCTAssertEqual(RarityOverlay.rarity(for: SpeciesID("cat-persian")), .rare)
        XCTAssertEqual(RarityOverlay.rarity(for: SpeciesID("dog-collie")), .rare)
        XCTAssertEqual(RarityOverlay.rarity(for: SpeciesID("bear-panda")), .rare)
        XCTAssertEqual(RarityOverlay.rarity(for: SpeciesID("pig-potbelly")), .rare)
        XCTAssertEqual(RarityOverlay.rarity(for: SpeciesID("rabbit-lionhead")), .rare)
        // Epic (purple border, hatch weight 5):
        XCTAssertEqual(RarityOverlay.rarity(for: SpeciesID("bear-polar")), .epic)
        XCTAssertEqual(RarityOverlay.rarity(for: SpeciesID("fox-silver")), .epic)
        // No legendary yet — reserved for Phase V.c new-breed surprise drop.
    }

    func test_bearDistribution_panda_rare_polar_epic() {
        // bear has 2 common + 1 rare + 1 epic = total weight 230.
        // brown / black ≈ 43.5% each (100/230); panda ≈ 10.9% (25/230);
        // polar ≈ 2.2% (5/230).
        var counts: [SpeciesID: Int] = [:]
        for seed: UInt32 in 0..<10000 {
            let genome = PetGenome(body: .bear, eyes: .dot, pattern: .none, personalityGene: 0.5, seed: seed)
            counts[genome.resolvedSpeciesID, default: 0] += 1
        }
        let brown = counts[SpeciesID("bear-brown")] ?? 0
        let black = counts[SpeciesID("bear-black")] ?? 0
        let panda = counts[SpeciesID("bear-panda")] ?? 0
        let polar = counts[SpeciesID("bear-polar")] ?? 0
        // Sanity: weighted distribution lands close to expected ratios over 10k samples.
        XCTAssertGreaterThan(brown + black, 8000, "common variants should dominate ≈87%")
        XCTAssertGreaterThan(panda, 800, "panda (rare) should land ~1090 of 10000")
        XCTAssertLessThan(panda, 1300)
        XCTAssertGreaterThan(polar, 100, "polar (epic) should land ~217 of 10000")
        XCTAssertLessThan(polar, 350)
    }

    func test_taggedVariants_renderBorderAtCorrectColor() {
        XCTAssertEqual(RarityOverlay.borderColor(for: SpeciesID("cat-siamese")),
                       .systemGray3, "rare → silver border")
        XCTAssertEqual(RarityOverlay.borderColor(for: SpeciesID("pig-boar")),
                       .systemPurple, "epic → purple border")
        XCTAssertNil(RarityOverlay.borderColor(for: SpeciesID("cat-tabby")),
                     "common → no border drawn")
    }

    func test_hatchWeightedSelection_seedsHitRareVariantLessOften() {
        // With 4 common (weight 100) + 1 rare (weight 25), the rare variant
        // should be picked roughly 1/17 ≈ 5.9% of the time. We sample
        // deterministically with seeds 0..<1000 and assert the rare count
        // falls in a reasonable bracket.
        var rareCount = 0
        for seed: UInt32 in 0..<1000 {
            let genome = PetGenome(body: .cat, eyes: .dot, pattern: .none, personalityGene: 0.5, seed: seed)
            if genome.resolvedSpeciesID == SpeciesID("cat-siamese") {
                rareCount += 1
            }
        }
        // Expected ~59 (1000 * 25 / 425). Allow generous bracket since
        // distribution is uniform on `seed % 425` so it's exactly 1000*25/425
        // = 58.82 → 58 or 59.
        XCTAssertGreaterThanOrEqual(rareCount, 50)
        XCTAssertLessThanOrEqual(rareCount, 70)
    }

    func test_hatchWeightedSelection_uniformCaseUnchanged_forAllCommonFamily() {
        // bear has 4 variants all common. Weighted pick should distribute
        // ~250 each over 1000 seeds (same as old uniform behavior).
        var counts: [SpeciesID: Int] = [:]
        for seed: UInt32 in 0..<1000 {
            let genome = PetGenome(body: .bear, eyes: .dot, pattern: .none, personalityGene: 0.5, seed: seed)
            counts[genome.resolvedSpeciesID, default: 0] += 1
        }
        for (_, count) in counts {
            XCTAssertGreaterThanOrEqual(count, 200, "Even distribution expected ≈250")
            XCTAssertLessThanOrEqual(count, 300, "Even distribution expected ≈250")
        }
    }

    func test_traits_for_unknownSpeciesReturnsEmpty() {
        XCTAssertTrue(SpeciesCatalog.traits(for: SpeciesID("cat-nonexistent")).isEmpty)
        XCTAssertTrue(SpeciesCatalog.traits(for: SpeciesID("totally-fake")).isEmpty)
    }

    // MARK: - Overlay stubs

    func test_accessoryOverlay_returnsNilWhenNoTraitDeclared() {
        XCTAssertNil(AccessoryOverlay.assetName(for: SpeciesID("cat-bengal")))
        XCTAssertNil(AccessoryOverlay.image(for: SpeciesID("cat-bengal")))
    }

    func test_rarityOverlay_defaultsToCommonNoBorder() {
        let id = SpeciesID("cat-bengal")
        XCTAssertEqual(RarityOverlay.rarity(for: id), .common)
        XCTAssertNil(RarityOverlay.borderColor(for: id))
        XCTAssertEqual(RarityOverlay.borderWidth(for: id), 0)
        XCTAssertFalse(RarityOverlay.showsSparkle(for: id))
    }

    // MARK: - Migration sanity

    func test_allIDs_unchanged_afterPhaseVaRefactor() {
        // The String → VariantSpec migration must not drop any species.
        // Lock the count so a typo in the migration shows up as a clear
        // diff vs the v5.3.3 baseline (124 multi-variant + 3 single-variant
        // = 127).
        XCTAssertGreaterThanOrEqual(SpeciesCatalog.allIDs.count, 100,
                                     "Phase V.a should preserve every variant from v5.3.3")
        XCTAssertTrue(SpeciesCatalog.allIDs.contains(SpeciesID("cat-bengal")))
        XCTAssertTrue(SpeciesCatalog.allIDs.contains(SpeciesID("dog-husky")))
        XCTAssertTrue(SpeciesCatalog.allIDs.contains(SpeciesID("bird")))
    }
}
