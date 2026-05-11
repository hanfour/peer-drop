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

    // MARK: - Evolution Progress

    func testEvolutionProgress() {
        // Fresh baby pet with 0 XP (baby→adult requires 500 XP)
        engine.pet.experience = 0
        XCTAssertEqual(engine.evolutionProgress, 0.0, accuracy: 0.001)

        // 50 XP out of 500 required
        engine.pet.experience = 50
        XCTAssertEqual(engine.evolutionProgress, 0.1, accuracy: 0.001)

        // 500 XP = full
        engine.pet.experience = 500
        XCTAssertEqual(engine.evolutionProgress, 1.0, accuracy: 0.001)

        // Over 500 XP should still cap at 1.0
        engine.pet.experience = 1000
        XCTAssertEqual(engine.evolutionProgress, 1.0, accuracy: 0.001)
    }
}
