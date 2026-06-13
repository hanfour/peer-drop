import XCTest
@testable import PeerDropPet

/// Hardening fixes surfaced by the 2026-06-13 deep pet-system audit:
/// FoodInventory input validation, evolution single-source-of-truth,
/// socialLog growth cap, and the advanceFrame bound guard.
@MainActor
final class PetSystemHardeningTests: XCTestCase {

    // MARK: - FoodInventory.add validation

    func testAddIgnoresNonPositiveCounts() {
        var inv = FoodInventory()
        let before = inv.count(of: .rice)
        inv.add(.rice, count: 0)
        inv.add(.rice, count: -5)
        XCTAssertEqual(inv.count(of: .rice), before, "non-positive add must be a no-op (never a negative count)")
    }

    func testAddSaturatesInsteadOfOverflowing() {
        var inv = FoodInventory()
        inv.add(.fish, count: Int.max)   // fish absent from defaults → new item at Int.max
        inv.add(.fish, count: 10)        // would overflow → must saturate
        XCTAssertEqual(inv.count(of: .fish), Int.max)
    }

    func testAddStillGrowsNormally() {
        var inv = FoodInventory()
        let before = inv.count(of: .rice)
        inv.add(.rice, count: 2)
        XCTAssertEqual(inv.count(of: .rice), before + 2)
    }

    // MARK: - Evolution single source of truth

    func testEngineConstantsDeriveFromEvolutionRequirement() {
        let adult = EvolutionRequirement.for(.adult)!
        XCTAssertEqual(PetEngine.adultToElderAgeDays, adult.minimumAge / 86400)
        XCTAssertEqual(PetEngine.adultToElderActivityWindowDays, adult.recentActivityWindow! / 86400)
    }

    func testBabyEvolvesJustOverRequirementAge() {
        let req = EvolutionRequirement.for(.baby)!
        var pet = PetState.newEgg(); pet.level = .baby; pet.genome.body = .cat
        pet.birthDate = Date().addingTimeInterval(-(req.minimumAge + 1))
        XCTAssertEqual(PetEngine(pet: pet).pet.level, .adult)
    }

    func testBabyStaysBabyJustUnderRequirementAge() {
        let req = EvolutionRequirement.for(.baby)!
        var pet = PetState.newEgg(); pet.level = .baby; pet.genome.body = .cat
        pet.birthDate = Date().addingTimeInterval(-(req.minimumAge - 3600))
        XCTAssertEqual(PetEngine(pet: pet).pet.level, .baby)
    }

    func testAdultEvolvesToElderWhenAgedAndRecentlyActive() {
        let req = EvolutionRequirement.for(.adult)!
        var pet = PetState.newEgg(); pet.level = .adult; pet.genome.body = .cat
        pet.birthDate = Date().addingTimeInterval(-(req.minimumAge + 86400))
        pet.lastInteraction = Date()
        XCTAssertEqual(PetEngine(pet: pet).pet.level, .elder)
    }

    func testAdultStaysAdultWhenAgedButInactive() {
        let req = EvolutionRequirement.for(.adult)!
        var pet = PetState.newEgg(); pet.level = .adult; pet.genome.body = .cat
        pet.birthDate = Date().addingTimeInterval(-(req.minimumAge + 86400))
        pet.lastInteraction = Date().addingTimeInterval(-(req.recentActivityWindow! + 86400))
        XCTAssertEqual(PetEngine(pet: pet).pet.level, .adult)
    }

    // MARK: - socialLog growth cap

    func testSocialLogIsCappedToMaxEntries() {
        let engine = PetEngine(pet: .newEgg())
        let greeting = PetGreeting(petID: UUID(), name: "Pal", level: .baby, mood: .happy, genome: .random())
        for _ in 0..<(PetEngine.maxSocialLogEntries + 50) {
            engine.handlePetMeeting(partnerGreeting: greeting)
        }
        XCTAssertEqual(engine.pet.socialLog.count, PetEngine.maxSocialLogEntries,
                       "socialLog must be capped at maxSocialLogEntries, not grow unbounded")
    }

    // MARK: - advanceFrame bound guard

    func testAdvanceFrameWithSingleFrameDoesNotTrap() {
        let c = PetAnimationController()
        c.setAction(.idle, frameCount: 1)  // totalFrames clamped to 1
        c.advanceFrame()                   // (0 + 1) % max(1, 1) — must not divide by zero
        XCTAssertEqual(c.currentFrame, 0)
    }
}
