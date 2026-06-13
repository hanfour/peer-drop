import XCTest
import PeerDropPet
@testable import PeerDropPet

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

    func testInitPromotesOverdueBabyWithoutInteraction() {
        // Audit round 16 (live finding): checkEvolution() only ran inside
        // interaction handlers, so a pet whose owner never taps it stayed
        // .baby forever — observed live at age 17/8 days. Passive aging
        // must be applied at engine startup too.
        var pet = PetState.newEgg()
        pet.level = .baby
        pet.genome.body = .cat
        pet.birthDate = Date().addingTimeInterval(-(17 * 86400))
        let engine = PetEngine(pet: pet)
        XCTAssertEqual(engine.pet.level, .adult,
                       "overdue baby must evolve at launch, not only on interaction")
    }

    func testInitKeepsYoungBabyUntouched() {
        var pet = PetState.newEgg()
        pet.level = .baby
        pet.genome.body = .cat
        pet.birthDate = Date().addingTimeInterval(-(2 * 86400))
        let engine = PetEngine(pet: pet)
        XCTAssertEqual(engine.pet.level, .baby)
    }

    func testAssigningOverdueBabyPromotesToAdult() {
        // Audit round 18 (live finding 2026-06-13): the round-16 init-time
        // checkEvolution only sees the `.newEgg()` PetEngine() is built
        // with — the REAL persisted pet is assigned afterwards via
        // `petEngine.pet = saved` (PeerDropApp.onAppear). That load path
        // never re-ran evolution, so a 17-day-old pet displayed "Age 17/8
        // days" while still labelled 幼年. Assignment of a replacement pet
        // must apply passive aging too.
        let engine = PetEngine(pet: .newEgg())  // fresh egg, age 0
        var saved = PetState.newEgg()
        saved.level = .baby
        saved.genome.body = .cat
        saved.birthDate = Date().addingTimeInterval(-(17 * 86400))
        engine.pet = saved
        XCTAssertEqual(engine.pet.level, .adult,
                       "loading an overdue baby must promote it, not just at init")
    }

    func testInPlayMutationDoesNotReEvaluateOrRecurse() {
        // The didSet evolution hook must fire only on pet REPLACEMENT
        // (id change), not on in-play field mutations — otherwise evolve()
        // mutating pet.level would re-enter checkEvolution. A young baby
        // whose mood/experience changes must stay .baby and not loop.
        var pet = PetState.newEgg()
        pet.level = .baby
        pet.genome.body = .cat
        pet.birthDate = Date().addingTimeInterval(-(2 * 86400))
        let engine = PetEngine(pet: pet)
        engine.pet.mood = .happy
        engine.pet.experience += 10
        XCTAssertEqual(engine.pet.level, .baby)
    }
}
