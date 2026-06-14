import XCTest
import PeerDropPet
@testable import PeerDropPet

final class BodyGeneMappingTests: XCTestCase {

    // MARK: - locked legacy mappings (plan §M2.3)

    func test_cat_mapsTo_catTabby() {
        XCTAssertEqual(BodyGene.cat.defaultSpeciesID, SpeciesID("cat-tabby"))
    }

    func test_dog_mapsTo_dogShiba() {
        XCTAssertEqual(BodyGene.dog.defaultSpeciesID, SpeciesID("dog-shiba"))
    }

    func test_rabbit_mapsTo_rabbitDutch() {
        XCTAssertEqual(BodyGene.rabbit.defaultSpeciesID, SpeciesID("rabbit-dutch"))
    }

    func test_bear_mapsTo_bearBrown() {
        XCTAssertEqual(BodyGene.bear.defaultSpeciesID, SpeciesID("bear-brown"))
    }

    func test_dragon_mapsTo_dragonWestern() {
        XCTAssertEqual(BodyGene.dragon.defaultSpeciesID, SpeciesID("dragon-western"))
    }

    func test_slime_mapsTo_slimeGreen() {
        XCTAssertEqual(BodyGene.slime.defaultSpeciesID, SpeciesID("slime-green"))
    }

    // MARK: - single-variety legacy families (no sub-variety in catalog)

    func test_bird_mapsTo_bareBird() {
        XCTAssertEqual(BodyGene.bird.defaultSpeciesID, SpeciesID("bird"))
    }

    func test_frog_mapsTo_bareFrog() {
        XCTAssertEqual(BodyGene.frog.defaultSpeciesID, SpeciesID("frog"))
    }

    func test_octopus_mapsTo_bareOctopus() {
        XCTAssertEqual(BodyGene.octopus.defaultSpeciesID, SpeciesID("octopus"))
    }

    // MARK: - round trip: BodyGene → SpeciesID.family preserves family token

    func test_speciesID_family_matchesBodyGeneRawValue_forAllCases() {
        for body in BodyGene.allCases {
            XCTAssertEqual(body.defaultSpeciesID.family, body.rawValue,
                           "family of \(body).defaultSpeciesID does not equal rawValue '\(body.rawValue)'")
        }
    }

    // MARK: - every mapped ID must resolve in the catalog

    func test_allMappedIDs_resolveInCatalog() {
        for body in BodyGene.allCases {
            XCTAssertNotNil(SpeciesCatalog.resolve(body.defaultSpeciesID),
                            "BodyGene.\(body) maps to \(body.defaultSpeciesID.rawValue) which does not resolve in SpeciesCatalog")
        }
    }

    // MARK: - every catalog family must be hatchable (no unreachable sprites)

    func test_everyCatalogFamilyHasABodyGene() {
        // Regression guard for the 2026-06-14 finding: a SpeciesCatalog family
        // with no matching BodyGene can never be produced by `resolvedSpeciesID`
        // (keyed on `body.rawValue`), so its bundled sprites are dead assets.
        // 25 families were unreachable (71% of bundle). Adding a catalog family
        // now requires adding the BodyGene case too — this test enforces it.
        let catalogFamilies = Set(SpeciesCatalog.allIDs.map(\.family))
        let bodyFamilies = Set(BodyGene.allCases.map(\.rawValue))
        let unreachable = catalogFamilies.subtracting(bodyFamilies).sorted()
        XCTAssertEqual(unreachable, [],
                       "SpeciesCatalog families with no BodyGene (unreachable sprites): \(unreachable)")
    }
}
