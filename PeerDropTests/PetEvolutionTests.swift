import XCTest
@testable import PeerDrop

@MainActor
final class PetEvolutionTests: XCTestCase {
    func testBabyEvolvesToChildAtThreshold() {
        var pet = PetState.newEgg()
        pet.level = .baby
        pet.genome.body = .cat
        pet.experience = 499
        pet.birthDate = Date().addingTimeInterval(-259201)
        let engine = PetEngine(pet: pet)
        engine.handleInteraction(.tap)
        XCTAssertEqual(engine.pet.level, .child)
    }

    func testBabyDoesNotEvolveWithoutEnoughTime() {
        var pet = PetState.newEgg()
        pet.level = .baby
        pet.genome.body = .cat
        pet.experience = 600
        pet.birthDate = Date()
        let engine = PetEngine(pet: pet)
        engine.handleInteraction(.tap)
        XCTAssertEqual(engine.pet.level, .baby)
    }

    func testBabyDoesNotEvolveWithoutEnoughXP() {
        var pet = PetState.newEgg()
        pet.level = .baby
        pet.genome.body = .cat
        pet.experience = 10
        pet.birthDate = Date().addingTimeInterval(-300000)
        let engine = PetEngine(pet: pet)
        engine.handleInteraction(.tap)
        XCTAssertEqual(engine.pet.level, .baby)
    }
}
