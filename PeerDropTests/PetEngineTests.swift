import XCTest
@testable import PeerDrop

@MainActor
final class PetEngineTests: XCTestCase {
    var engine: PetEngine!

    override func setUp() async throws {
        try await super.setUp()
        engine = PetEngine(pet: .newEgg())
    }

    override func tearDown() async throws {
        engine = nil
        try await super.tearDown()
    }

    // MARK: - Initial State

    func testInitialState() {
        XCTAssertEqual(engine.pet.level, .baby)
        XCTAssertEqual(engine.currentAction, .idle)
    }

    // MARK: - Interaction

    func testHandleInteractionAddsExperience() {
        let before = engine.pet.experience
        engine.handleInteraction(.tap)
        XCTAssertEqual(engine.pet.experience, before + 2)
    }

    func testHandleInteractionUpdatesMood() {
        // A single tap within 10 min should yield .curious
        engine.handleInteraction(.tap)
        XCTAssertEqual(engine.pet.mood, .curious)
    }

    func testMoodBecomesHappyWithManyInteractions() {
        // Use non-tap interactions (no cooldown) to get 5+ in 10 min → .happy
        for _ in 0..<6 {
            engine.handleInteraction(.peerConnected)
        }
        XCTAssertEqual(engine.pet.mood, .happy)
    }

    // MARK: - Evolution

    func testEvolutionDoesNotOccurBeforeMinimumAge() {
        // Pet was just born — baby→adult requires 8 days in checkEvolution().
        // Even with lots of XP, age-only rule keeps level at .baby.
        engine.pet.experience = 600
        engine.handleInteraction(.tap)
        XCTAssertEqual(engine.pet.level, .baby, "Should not evolve before minimum age")
    }

    func testEvolutionOccursWhenReady() {
        // Set birthDate to 9 days ago so age-based rule (8 days) is met.
        // checkEvolution() is age-only — XP threshold lives in the separate
        // EvolutionRequirement type used by the UI progress bar.
        engine.pet.birthDate = Date().addingTimeInterval(-9 * 86400)
        engine.handleInteraction(.tap)
        XCTAssertEqual(engine.pet.level, .adult, "Should evolve to adult when age requirement is met")
    }

    // MARK: - Pet Meeting

    func testPetMeetingAddsSocialLog() {
        let greeting = PetGreeting(
            petID: UUID(),
            name: "PartnerPet",
            level: .baby,
            mood: .happy,
            genome: .random()
        )
        engine.handlePetMeeting(partnerGreeting: greeting)
        XCTAssertEqual(engine.pet.socialLog.count, 1)
        XCTAssertEqual(engine.pet.socialLog.first?.partnerName, "PartnerPet")
        XCTAssertEqual(engine.pet.socialLog.first?.isRevealed, false)
    }

    // MARK: - Life State

    func testLifeStateBasedOnTime() {
        let state = engine.currentLifeState
        // Should return a valid PetLifeState (any value is valid based on time of day)
        XCTAssertTrue(PetLifeState.allCases.contains(state))
    }

    // MARK: - Personality Reaction

    func testPersonalityReaction() {
        let action = engine.reactionForEvent(.tap)
        // Should return a valid PetAction (not nil)
        XCTAssertNotNil(action)
        // The reaction should be one of the defined actions for tap
        let validTapActions: [PetAction] = [.ignore, .freeze, .wagTail]
        XCTAssertTrue(validTapActions.contains(action),
                      "Tap reaction should be .ignore, .freeze, or .wagTail, got \(action)")
    }

    // MARK: - Evolution Progress

    // MARK: - Behavior Provider

    func testEngineHasBehaviorProvider() {
        let engine = PetEngine()
        XCTAssertNotNil(engine.behaviorProvider)
    }

    func testEngineProviderMatchesBody() {
        var genome = PetGenome.random()
        genome.body = .bird
        var pet = PetState.newEgg()
        pet.genome = genome
        let engine = PetEngine(pet: pet)
        XCTAssertEqual(engine.behaviorProvider.profile.physicsMode, .flying)
    }

    // MARK: - Evolution Progress (v5.0.x: age-based)

    func testEvolutionProgress_freshBaby_isZero() {
        engine.pet.birthDate = Date()
        XCTAssertEqual(engine.evolutionProgress, 0.0, accuracy: 0.001)
    }

    func testEvolutionProgress_babyHalfway_isHalf() {
        // Halfway through the 8-day baby window.
        engine.pet.birthDate = Date().addingTimeInterval(-4 * 86400)
        XCTAssertEqual(engine.evolutionProgress, 0.5, accuracy: 0.005)
    }

    func testEvolutionProgress_babyPastThreshold_capsAtOne() {
        // 20 days old — past the 8-day baby→adult gate.
        engine.pet.birthDate = Date().addingTimeInterval(-20 * 86400)
        XCTAssertEqual(engine.evolutionProgress, 1.0, accuracy: 0.001)
    }

    func testEvolutionProgress_adult_isAgeBased() {
        // Adult at 45 days, halfway through the 90-day adult→elder gate.
        engine.pet.level = .adult
        engine.pet.birthDate = Date().addingTimeInterval(-45 * 86400)
        XCTAssertEqual(engine.evolutionProgress, 0.5, accuracy: 0.005)
    }

    func testEvolutionProgress_elder_isFull() {
        // Elder is the final stage — no further evolution gate.
        engine.pet.level = .elder
        XCTAssertEqual(engine.evolutionProgress, 1.0, accuracy: 0.001)
    }
}
