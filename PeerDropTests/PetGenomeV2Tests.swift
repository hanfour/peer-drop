import XCTest
@testable import PeerDrop

final class PetGenomeV2Tests: XCTestCase {

    func testBodyGeneHas10Cases() {
        XCTAssertEqual(BodyGene.allCases.count, 10)
    }

    func testBodyGeneFromPersonalityGene() {
        XCTAssertEqual(BodyGene.from(personalityGene: 0.05), .cat)
        XCTAssertEqual(BodyGene.from(personalityGene: 0.75), .dragon)
        XCTAssertEqual(BodyGene.from(personalityGene: 0.95), .slime)
    }

    func testPaletteIndexDecoupledFromBody() {
        let g1 = PetGenome(body: .cat, eyes: .dot, pattern: .none, personalityGene: 0.05)
        let g2 = PetGenome(body: .cat, eyes: .dot, pattern: .none, personalityGene: 0.06)
        XCTAssertTrue((0..<8).contains(g1.paletteIndex))
        XCTAssertTrue((0..<8).contains(g2.paletteIndex))
    }

    func testLevelHasChildCase() {
        XCTAssertEqual(PetLevel.child.rawValue, 3)
        XCTAssertTrue(PetLevel.baby < PetLevel.child)
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
