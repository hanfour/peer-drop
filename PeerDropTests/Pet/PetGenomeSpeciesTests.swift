import XCTest
@testable import PeerDrop

final class PetGenomeSpeciesTests: XCTestCase {

    // Helper — a baseline genome we can mutate per test.
    private func baseGenome(body: BodyGene = .cat) -> PetGenome {
        PetGenome(body: body, eyes: .dot, pattern: .none, personalityGene: 0.5)
    }

    // MARK: - new fields default to nil (manual init via baseGenome helper)

    func test_baseGenome_hasNilSubVariety_andNilSeed() {
        let g = baseGenome()
        XCTAssertNil(g.subVariety)
        XCTAssertNil(g.seed)
    }

    // MARK: - PetGenome.random() seeds for variety

    func test_random_setsSeed_soFreshPetsGetVariantPick() {
        let g = PetGenome.random()
        XCTAssertNotNil(g.seed,
                        "random() must set seed — without it, all v4.0 fresh pets render as canonical default variants")
    }

    func test_random_doesNotSetSubVariety_letsSeedDriveVariantPick() {
        let g = PetGenome.random()
        XCTAssertNil(g.subVariety,
                     "random() should not pin subVariety — that path is reserved for migration / explicit user choice")
    }

    func test_random_consecutiveCalls_haveDifferentSeeds() {
        // UInt32 collision probability ~2^-32 — effectively impossible.
        let g1 = PetGenome.random()
        let g2 = PetGenome.random()
        XCTAssertNotEqual(g1.seed, g2.seed)
    }

    // MARK: - Codable: legacy JSON (no subVariety / seed) decodes as nil

    func test_legacyJSON_withoutSubVarietyOrSeed_decodesAsNil() throws {
        var g = baseGenome()
        let data = try JSONEncoder().encode(g)
        var dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        dict.removeValue(forKey: "subVariety")
        dict.removeValue(forKey: "seed")
        let stripped = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(PetGenome.self, from: stripped)
        XCTAssertNil(decoded.subVariety)
        XCTAssertNil(decoded.seed)
        XCTAssertEqual(decoded.body, g.body)
        _ = g
    }

    // MARK: - Codable: round-trip preserves both fields

    func test_codable_roundTrip_preservesSubVarietyAndSeed() throws {
        var g = baseGenome()
        g.subVariety = "tabby"
        g.seed = 12345
        let data = try JSONEncoder().encode(g)
        let decoded = try JSONDecoder().decode(PetGenome.self, from: data)
        XCTAssertEqual(decoded.subVariety, "tabby")
        XCTAssertEqual(decoded.seed, 12345)
    }

    // MARK: - resolvedSpeciesID: pinned subVariety wins

    func test_resolvedSpeciesID_usesPinnedSubVariety_whenPresent() {
        var g = baseGenome(body: .cat)
        g.subVariety = "siamese"
        XCTAssertEqual(g.resolvedSpeciesID, SpeciesID("cat-siamese"))
    }

    func test_resolvedSpeciesID_usesPinnedSubVariety_evenWhenSeedAlsoPresent() {
        var g = baseGenome(body: .cat)
        g.subVariety = "persian"
        g.seed = 999
        XCTAssertEqual(g.resolvedSpeciesID, SpeciesID("cat-persian"))
    }

    func test_resolvedSpeciesID_pinnedSubVariety_passesThrough_evenIfNotInCatalog() {
        // subVariety is treated as raw caller intent — not validated against the
        // catalog. Caller (M3 SpriteService) is responsible for catalog lookup +
        // fallback. This test pins that contract so future validation additions
        // are intentional.
        var g = baseGenome(body: .cat)
        g.subVariety = "imaginary"
        XCTAssertEqual(g.resolvedSpeciesID, SpeciesID("cat-imaginary"))
    }

    // MARK: - resolvedSpeciesID: seed-based deterministic pick when no pin

    func test_resolvedSpeciesID_seed0_returnsFirstVariant() {
        var g = baseGenome(body: .cat)
        g.seed = 0
        // SpeciesCatalog cat variants are ["tabby", "bengal", "calico", "persian", "siamese"]
        XCTAssertEqual(g.resolvedSpeciesID, SpeciesID("cat-tabby"))
    }

    func test_resolvedSpeciesID_seed_picksDeterministically() {
        var g = baseGenome(body: .cat)
        g.seed = 2
        // seed % 5 = 2 → variants[2] = "calico"
        XCTAssertEqual(g.resolvedSpeciesID, SpeciesID("cat-calico"))
    }

    func test_resolvedSpeciesID_seedWrapsAroundVariantCount() {
        var g = baseGenome(body: .cat)
        g.seed = 5  // 5 % 5 = 0 → variants[0] = "tabby"
        XCTAssertEqual(g.resolvedSpeciesID, SpeciesID("cat-tabby"))
    }

    func test_resolvedSpeciesID_seed_isStableAcrossCalls() {
        var g = baseGenome(body: .dog)
        g.seed = 17
        let first = g.resolvedSpeciesID
        let second = g.resolvedSpeciesID
        XCTAssertEqual(first, second)
    }

    // MARK: - resolvedSpeciesID: fallback when neither pin nor seed

    func test_resolvedSpeciesID_fallsBackToBodyDefault_whenNeitherSet() {
        let g = baseGenome(body: .cat)
        XCTAssertEqual(g.resolvedSpeciesID, BodyGene.cat.defaultSpeciesID)
    }

    func test_resolvedSpeciesID_singleVarietyFamily_ignoresSeed() {
        var g = baseGenome(body: .octopus)
        g.seed = 999
        // octopus has no sub-varieties → seeded pick falls through to bare family ID
        XCTAssertEqual(g.resolvedSpeciesID, SpeciesID("octopus"))
    }
}
