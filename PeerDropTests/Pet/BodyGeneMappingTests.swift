import XCTest
@testable import PeerDrop

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

    // MARK: - ghost: no assets in v4.0 catalog (M3 loader handles fallback)

    func test_ghost_mapsTo_bareGhost() {
        XCTAssertEqual(BodyGene.ghost.defaultSpeciesID, SpeciesID("ghost"))
    }

    // MARK: - round trip: BodyGene → SpeciesID.family preserves family token

    func test_speciesID_family_matchesBodyGeneRawValue_forAllCases() {
        for body in BodyGene.allCases {
            XCTAssertEqual(body.defaultSpeciesID.family, body.rawValue,
                           "family of \(body).defaultSpeciesID does not equal rawValue '\(body.rawValue)'")
        }
    }

    // MARK: - all mapped IDs (except ghost) must resolve in the catalog

    func test_allMappedIDs_exceptGhost_resolveInCatalog() {
        for body in BodyGene.allCases where body != .ghost {
            XCTAssertNotNil(SpeciesCatalog.resolve(body.defaultSpeciesID),
                            "BodyGene.\(body) maps to \(body.defaultSpeciesID.rawValue) which does not resolve in SpeciesCatalog")
        }
    }
}
