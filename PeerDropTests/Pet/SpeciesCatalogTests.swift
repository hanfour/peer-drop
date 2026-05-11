import XCTest
@testable import PeerDrop

final class SpeciesCatalogTests: XCTestCase {

    // MARK: - allIDs / contains

    func test_allIDs_isNonEmpty() {
        XCTAssertFalse(SpeciesCatalog.allIDs.isEmpty)
    }

    func test_allIDs_countMatchesAssetSet() {
        // Locks the catalog size against the current zip set under
        // docs/pet-design/ai-brief/species-zips-stages/. Update this when assets
        // are added or removed during the gen sprint.
        // Breakdown: 31 multi-variety families × their variants = 101 IDs,
        // + 3 single-variety legacy families (bird, frog, octopus) = 104.
        XCTAssertEqual(SpeciesCatalog.allIDs.count, 104)
    }

    func test_allIDs_areUnique() {
        let set = Set(SpeciesCatalog.allIDs)
        XCTAssertEqual(set.count, SpeciesCatalog.allIDs.count, "duplicate SpeciesIDs in catalog")
    }

    func test_allIDs_familiesAreSortedAlphabetically() {
        // Pins the deterministic order — Swift Dict iteration is unstable across
        // builds, so we sort family keys explicitly.
        var lastFamily = ""
        for id in SpeciesCatalog.allIDs {
            XCTAssertGreaterThanOrEqual(id.family, lastFamily,
                                         "allIDs not sorted alphabetically by family at id=\(id.rawValue)")
            lastFamily = id.family
        }
    }

    func test_allIDs_firstID_isBearBrown() {
        // bear is alphabetically the first family; brown is the locked default variant.
        XCTAssertEqual(SpeciesCatalog.allIDs.first, SpeciesID("bear-brown"))
    }

    func test_allIDs_containsCanonicalLegacyMappings() {
        // Plan §M2.3 locked picks — these must all resolve.
        let canonical: [String] = [
            "cat-tabby", "dog-shiba", "rabbit-dutch", "bear-brown",
            "dragon-western", "slime-green", "totoro-grey",
        ]
        for id in canonical {
            XCTAssertTrue(SpeciesCatalog.allIDs.contains(SpeciesID(id)),
                          "allIDs missing canonical legacy mapping: \(id)")
        }
    }

    func test_allIDs_containsSingleVarietyLegacyFamilies() {
        // bird, frog, octopus exist as zip-bearing families with no sub-variety
        // → SpeciesID is the bare family name.
        for id in ["bird", "frog", "octopus"] {
            XCTAssertTrue(SpeciesCatalog.allIDs.contains(SpeciesID(id)),
                          "allIDs missing single-variety legacy family: \(id)")
        }
    }

    // MARK: - familyDefault

    func test_familyDefault_cat_returnsTabby() {
        XCTAssertEqual(SpeciesCatalog.familyDefault(for: "cat"),
                       SpeciesID("cat-tabby"))
    }

    func test_familyDefault_dog_returnsShiba() {
        XCTAssertEqual(SpeciesCatalog.familyDefault(for: "dog"),
                       SpeciesID("dog-shiba"))
    }

    func test_familyDefault_singleVarietyFamily_returnsBareID() {
        // octopus has no sub-varieties → the family-only ID is the default.
        XCTAssertEqual(SpeciesCatalog.familyDefault(for: "octopus"),
                       SpeciesID("octopus"))
    }

    func test_familyDefault_unknownFamily_returnsNil() {
        XCTAssertNil(SpeciesCatalog.familyDefault(for: "madeupfamily"))
    }

    // MARK: - resolve fallback chain

    func test_resolve_exactMatch_returnsInput() {
        XCTAssertEqual(SpeciesCatalog.resolve(SpeciesID("cat-tabby")),
                       SpeciesID("cat-tabby"))
    }

    func test_resolve_unknownVariant_returnsFamilyDefault() {
        XCTAssertEqual(SpeciesCatalog.resolve(SpeciesID("cat-imaginary")),
                       SpeciesID("cat-tabby"))
    }

    func test_resolve_unknownFamily_returnsNil() {
        XCTAssertNil(SpeciesCatalog.resolve(SpeciesID("madeup-anything")))
    }

    func test_resolve_singleVarietyFamily_exactMatch() {
        XCTAssertEqual(SpeciesCatalog.resolve(SpeciesID("octopus")),
                       SpeciesID("octopus"))
    }
}
