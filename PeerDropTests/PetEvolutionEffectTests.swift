import XCTest
@testable import PeerDrop

@MainActor
final class PetEvolutionEffectTests: XCTestCase {
    func testEvolutionSetsShowFlashFlag() {
        var pet = PetState.newEgg()
        pet.level = .baby
        pet.genome.body = .cat
        pet.experience = 499
        pet.birthDate = Date().addingTimeInterval(-259201)
        let engine = PetEngine(pet: pet)
        engine.handleInteraction(.tap)
        XCTAssertEqual(engine.pet.level, .child)
        XCTAssertTrue(engine.showEvolutionFlash)
    }
}
