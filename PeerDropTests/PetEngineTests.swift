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
        XCTAssertEqual(engine.pet.level, .egg)
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
        // Give lots of XP but pet was just born
        engine.pet.experience = 600
        engine.handleInteraction(.tap)
        XCTAssertEqual(engine.pet.level, .egg, "Should not evolve before minimum age")
    }

    func testEvolutionOccursWhenReady() {
        // Set birthDate to 2 days ago so minimum age (86400s) is met
        engine.pet.birthDate = Date().addingTimeInterval(-2 * 86400)
        // Give enough XP: requirement is 100
        engine.pet.experience = 98
        // One tap adds 2 XP → total 100
        engine.handleInteraction(.tap)
        XCTAssertEqual(engine.pet.level, .baby, "Should evolve to baby when XP and age requirements are met")
    }

    func testSocialBonusAcceleratesEvolution() {
        // Set birthDate to 2 days ago
        engine.pet.birthDate = Date().addingTimeInterval(-2 * 86400)
        // Add a recent social log entry so hasSocialRecently == true
        let socialEntry = SocialEntry(
            partnerPetID: UUID(),
            partnerName: "TestPet",
            date: Date(), // recent
            interaction: .chat,
            dialogue: [],
            isRevealed: false
        )
        engine.pet.socialLog.append(socialEntry)
        // With socialBonus=1.5, we need effectiveExp >= 100
        // 67 * 1.5 = 100.5 >= 100
        engine.pet.experience = 66
        // One tap adds 2 → 68 * 1.5 = 102
        engine.handleInteraction(.tap)
        XCTAssertEqual(engine.pet.level, .baby, "Social bonus should accelerate evolution")
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

    func testEvolutionProgress() {
        // Fresh egg with 0 XP
        engine.pet.experience = 0
        XCTAssertEqual(engine.evolutionProgress, 0.0, accuracy: 0.001)

        // 10 XP out of 100 required
        engine.pet.experience = 10
        XCTAssertEqual(engine.evolutionProgress, 0.1, accuracy: 0.001)

        // 100 XP = full
        engine.pet.experience = 100
        XCTAssertEqual(engine.evolutionProgress, 1.0, accuracy: 0.001)

        // Over 100 XP should still cap at 1.0
        engine.pet.experience = 200
        XCTAssertEqual(engine.evolutionProgress, 1.0, accuracy: 0.001)
    }
}
