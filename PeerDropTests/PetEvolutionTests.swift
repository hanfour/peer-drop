import XCTest
@testable import PeerDrop

@MainActor
final class PetEvolutionTests: XCTestCase {
    func testBabyEvolvesToAdultAtThreshold() {
        // v4.0: baby→adult is age-only at 8 days (was 3 days + 500 XP).
        var pet = PetState.newEgg()
        pet.level = .baby
        pet.genome.body = .cat
        pet.birthDate = Date().addingTimeInterval(-(8 * 86400 + 1))
        let engine = PetEngine(pet: pet)
        engine.handleInteraction(.tap)
        XCTAssertEqual(engine.pet.level, .adult)
    }

    func testBabyDoesNotEvolveWithoutEnoughTime() {
        // Even with high experience, age (<8 days) gates baby→adult promotion in v4.0.
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

    func testEvolutionMutationIsRare() {
        // Run 200 evolutions — with 10% rate we expect ~20 mutations.
        // If rate were 100% we'd get 200. Assert < 80 to catch the bug.
        var mutations = 0
        for _ in 0..<200 {
            var pet = PetState.newEgg()
            pet.level = .baby
            pet.genome.body = .cat
            pet.genome.eyes = .dot
            pet.genome.pattern = .none
            pet.birthDate = Date().addingTimeInterval(-(8 * 86400 + 1))
            let engine = PetEngine(pet: pet)
            engine.handleInteraction(.tap)
            if engine.pet.genome.eyes != .dot || engine.pet.genome.pattern != .none {
                mutations += 1
            }
        }
        XCTAssertLessThan(mutations, 80, "Mutation rate should be ~10%, got \(mutations)/200")
        // Also verify it CAN happen (at least 1 in 200 trials)
        XCTAssertGreaterThan(mutations, 0, "At least one mutation should occur in 200 trials")
    }
}
