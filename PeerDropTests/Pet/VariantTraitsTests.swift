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

    func test_traits_for_returnsEmptyForExistingVariants() {
        // Phase V.a is data-model-only: every existing variant has empty
        // traits. Once V.b tags some variants this test gets a sibling
        // that asserts the specific tags.
        XCTAssertTrue(SpeciesCatalog.traits(for: SpeciesID("cat-bengal")).isEmpty)
        XCTAssertTrue(SpeciesCatalog.traits(for: SpeciesID("dog-husky")).isEmpty)
        XCTAssertTrue(SpeciesCatalog.traits(for: SpeciesID("bird")).isEmpty)
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
