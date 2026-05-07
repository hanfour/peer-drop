import XCTest
@testable import PeerDrop

final class SpriteAssetResolverTests: XCTestCase {

    // MARK: - filename: deterministic <species-id>-<stage>

    func test_filename_catTabbyAdult() {
        let req = SpriteRequest(species: SpeciesID("cat-tabby"), stage: .adult, direction: .east)
        XCTAssertEqual(SpriteAssetResolver.filename(for: req), "cat-tabby-adult")
    }

    func test_filename_octopusBaby_singleVarietyFamily() {
        let req = SpriteRequest(species: SpeciesID("octopus"), stage: .baby, direction: .south)
        XCTAssertEqual(SpriteAssetResolver.filename(for: req), "octopus-baby")
    }

    func test_filename_allStages_emitSpeciesPrefixedSuffix() {
        let cases: [(PetLevel, String)] = [
            (.baby,  "baby"),
            (.adult, "adult"),
            (.elder, "elder"),
        ]
        for (stage, expectedSuffix) in cases {
            let req = SpriteRequest(species: SpeciesID("cat-tabby"), stage: stage, direction: .east)
            XCTAssertEqual(SpriteAssetResolver.filename(for: req),
                           "cat-tabby-\(expectedSuffix)")
        }
    }

    func test_filename_unknownFamily_returnsNil() {
        // Tightened API contract (was: returned a garbage "madeup-anything-adult"
        // string). Callers can now distinguish "no asset for this request" from
        // a valid filename without redundant catalog lookups.
        let req = SpriteRequest(species: SpeciesID("madeup-anything"), stage: .adult, direction: .east)
        XCTAssertNil(SpriteAssetResolver.filename(for: req))
    }

    func test_filename_isDirectionIndependent() {
        // Direction is decoded from inside the zip — not part of the filename.
        let east = SpriteRequest(species: SpeciesID("cat-tabby"), stage: .adult, direction: .east)
        let west = SpriteRequest(species: SpeciesID("cat-tabby"), stage: .adult, direction: .west)
        XCTAssertEqual(SpriteAssetResolver.filename(for: east),
                       SpriteAssetResolver.filename(for: west))
    }

    // MARK: - url: bundle lookup with catalog-aware fallback

    private var testBundle: Bundle { Bundle(for: type(of: self)) }

    func test_url_findsCatTabbyAdult_inTestBundle() throws {
        // The M0 spike fixture cat-tabby-adult.zip is bundled.
        let req = SpriteRequest(species: SpeciesID("cat-tabby"), stage: .adult, direction: .east)
        let url = SpriteAssetResolver.url(for: req, in: testBundle)
        XCTAssertNotNil(url, "resolver should locate the bundled cat-tabby-adult.zip")
        XCTAssertEqual(url?.lastPathComponent, "cat-tabby-adult.zip")
    }

    func test_url_unknownVariant_fallsBackToFamilyDefault() throws {
        // cat-imaginary is unknown; cat family default is cat-tabby; that zip is
        // bundled → resolver should find cat-tabby-adult.zip.
        let req = SpriteRequest(species: SpeciesID("cat-imaginary"), stage: .adult, direction: .east)
        let url = SpriteAssetResolver.url(for: req, in: testBundle)
        XCTAssertEqual(url?.lastPathComponent, "cat-tabby-adult.zip")
    }

    func test_url_unknownFamily_returnsNil() {
        let req = SpriteRequest(species: SpeciesID("madeup-anything"), stage: .adult, direction: .east)
        let url = SpriteAssetResolver.url(for: req, in: testBundle)
        XCTAssertNil(url)
    }

    func test_url_knownSpeciesButMissingZip_returnsNil() {
        // cat-tabby is in the catalog, but only the adult zip is bundled in tests.
        // Requesting baby should return nil (no fallback to a different stage).
        let req = SpriteRequest(species: SpeciesID("cat-tabby"), stage: .baby, direction: .east)
        let url = SpriteAssetResolver.url(for: req, in: testBundle)
        XCTAssertNil(url, "missing-stage zip should return nil — fallback only across species, not stages")
    }
}
