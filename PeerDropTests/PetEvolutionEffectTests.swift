import XCTest
@testable import PeerDrop

@MainActor
final class PetEvolutionEffectTests: XCTestCase {
    func testEvolutionSetsShowFlashFlag() {
        // v4.0: baby→adult is age-only at 8 days.
        var pet = PetState.newEgg()
        pet.level = .baby
        pet.genome.body = .cat
        pet.birthDate = Date().addingTimeInterval(-(8 * 86400 + 1))
        let engine = PetEngine(pet: pet)
        engine.handleInteraction(.tap)
        XCTAssertEqual(engine.pet.level, .adult)
        XCTAssertTrue(engine.showEvolutionFlash)
    }
}
