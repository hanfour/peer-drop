import XCTest
import PeerDropPet
@testable import PeerDropPet

final class PetGenomeV2Tests: XCTestCase {

    func testBodyGeneHasAllFamilyCases() {
        // Expanded 9 → 34 (2026-06-14) so every SpeciesCatalog family is
        // hatchable (the expansion families' sprites were previously dead).
        XCTAssertEqual(BodyGene.allCases.count, 34)
    }

    func testCatDominatesHatchDistribution() {
        // Cat stays the most common family (best v5 walk/idle coverage).
        XCTAssertEqual(BodyGene.from(personalityGene: 0.0), .cat)
        XCTAssertEqual(BodyGene.from(personalityGene: 0.1), .cat)
    }

    func testEveryBodyGeneIsHatchable() {
        // Sweep [0,1): every family must be reachable by some personalityGene,
        // else its bundled sprites are unreachable (the exact bug this fixes).
        var seen = Set<BodyGene>()
        var pg = 0.0
        while pg < 1.0 { seen.insert(BodyGene.from(personalityGene: pg)); pg += 0.0005 }
        XCTAssertEqual(seen, Set(BodyGene.allCases),
                       "unreachable: \(Set(BodyGene.allCases).subtracting(seen).map(\.rawValue).sorted())")
    }

    func testPaletteIndexDecoupledFromBody() {
        let g1 = PetGenome(body: .cat, eyes: .dot, pattern: .none, personalityGene: 0.05)
        let g2 = PetGenome(body: .cat, eyes: .dot, pattern: .none, personalityGene: 0.06)
        XCTAssertTrue((0..<8).contains(g1.paletteIndex))
        XCTAssertTrue((0..<8).contains(g2.paletteIndex))
    }

    func testLevelHasAdultCase() {
        XCTAssertEqual(PetLevel.adult.rawValue, 3)
        XCTAssertTrue(PetLevel.baby < PetLevel.adult)
    }

    func testPetSurfaceCases() {
        let surfaces: [PetSurface] = [.ground, .leftWall, .rightWall, .ceiling, .dynamicIsland, .airborne]
        XCTAssertEqual(surfaces.count, 6)
    }

    func testNewActionCases() {
        let actions: [PetAction] = [.run, .jump, .climb, .hang, .fall, .sitEdge,
                                     .eat, .yawn, .poop, .happy, .scared, .angry,
                                     .love, .tapReact, .pickedUp, .thrown, .petted]
        XCTAssertFalse(actions.isEmpty)
    }

    func testOldBodyGenesMigrate() {
        let json = """
        {"body":"round","eyes":"dot","pattern":"none","personalityGene":0.5}
        """
        let genome = try? JSONDecoder().decode(PetGenome.self, from: json.data(using: .utf8)!)
        XCTAssertNotNil(genome)
        XCTAssertEqual(genome?.body, .bear)
    }
}
