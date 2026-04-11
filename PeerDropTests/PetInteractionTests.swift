import XCTest
@testable import PeerDrop

@MainActor
final class PetInteractionTests: XCTestCase {
    func testPoopCleaningGivesXP() {
        var pet = PetState.newEgg()
        pet.level = .baby
        let engine = PetEngine(pet: pet)
        engine.poopState.drop(at: CGPoint(x: 100, y: 700))
        let xpBefore = engine.pet.experience
        let poopID = engine.poopState.poops.first!.id
        engine.cleanPoop(id: poopID)
        XCTAssertEqual(engine.pet.experience, xpBefore + 1)
        XCTAssertTrue(engine.poopState.poops.isEmpty)
    }

    func testPetStrokeGivesXP() {
        var pet = PetState.newEgg()
        pet.level = .baby
        let engine = PetEngine(pet: pet)
        let xpBefore = engine.pet.experience
        engine.handlePetStroke()
        XCTAssertEqual(engine.pet.experience, xpBefore + 3)
    }
}
