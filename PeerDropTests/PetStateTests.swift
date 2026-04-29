import XCTest
@testable import PeerDrop

@MainActor
final class PetStateTests: XCTestCase {

    // MARK: - PetLevel

    func testPetLevelOrdering() {
        XCTAssertTrue(PetLevel.egg < PetLevel.baby)
        XCTAssertFalse(PetLevel.baby < PetLevel.egg)
    }

    func testPetLevelRawValues() {
        XCTAssertEqual(PetLevel.egg.rawValue, 1)
        XCTAssertEqual(PetLevel.baby.rawValue, 2)
    }

    func testPetLevelCaseIterable() {
        XCTAssertEqual(PetLevel.allCases.count, 4)
    }

    // MARK: - PetGenome

    func testCanvasSize() {
        XCTAssertEqual(PetGenome.canvasSize, 16)
    }

    func testGenomeMutation() {
        var genome = PetGenome.random()
        let original = genome

        var changed = false
        for _ in 0..<100 {
            genome.mutate(trigger: .evolution) // 100% chance
            if genome != original {
                changed = true
                break
            }
        }
        XCTAssertTrue(changed, "Genome should change after 100 evolution mutations")
    }

    func testGenomeMutationEvolutionAlwaysMutates() {
        // Evolution trigger should always mutate (100% chance)
        var mutationCount = 0
        for _ in 0..<20 {
            var genome = PetGenome.random()
            let original = genome
            genome.mutate(trigger: .evolution)
            if genome != original {
                mutationCount += 1
            }
        }
        // All 20 should mutate (evolution = 100% chance)
        XCTAssertEqual(mutationCount, 20, "Evolution trigger should always cause mutation")
    }

    func testPersonalityTraitsInRange() {
        for _ in 0..<50 {
            let genome = PetGenome.random()
            let traits = genome.personalityTraits
            XCTAssertTrue((0.0...1.0).contains(traits.independence), "independence \(traits.independence) out of range")
            XCTAssertTrue((0.0...1.0).contains(traits.curiosity), "curiosity \(traits.curiosity) out of range")
            XCTAssertTrue((0.0...1.0).contains(traits.energy), "energy \(traits.energy) out of range")
            XCTAssertTrue((0.0...1.0).contains(traits.timidity), "timidity \(traits.timidity) out of range")
            XCTAssertTrue((0.0...1.0).contains(traits.mischief), "mischief \(traits.mischief) out of range")
        }
    }

    func testGenomeRandom() {
        let g1 = PetGenome.random()
        // Just verify it creates valid values
        XCTAssertTrue((0.0...1.0).contains(g1.personalityGene))
        XCTAssertTrue(BodyGene.allCases.contains(g1.body))
        XCTAssertTrue(EyeGene.allCases.contains(g1.eyes))
    }

    // MARK: - PetState

    func testNewEggStartsAsEggWithZeroXP() {
        let pet = PetState.newEgg()
        XCTAssertEqual(pet.level, .egg)
        XCTAssertEqual(pet.experience, 0)
        XCTAssertNil(pet.name)
        XCTAssertTrue(pet.socialLog.isEmpty)
    }

    func testPetStateCodableRoundTrip() throws {
        let original = PetState.newEgg()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PetState.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.level, original.level)
        XCTAssertEqual(decoded.experience, original.experience)
        XCTAssertEqual(decoded.mood, original.mood)
        XCTAssertEqual(decoded.genome, original.genome)
        XCTAssertEqual(decoded.name, original.name)
    }

    // MARK: - PetMood

    func testAllMoodsCodable() throws {
        for mood in PetMood.allCases {
            let data = try JSONEncoder().encode(mood)
            let decoded = try JSONDecoder().decode(PetMood.self, from: data)
            XCTAssertEqual(decoded, mood)
        }
    }

    func testMoodDisplayNames() {
        XCTAssertEqual(PetMood.happy.displayName, "開心")
        XCTAssertEqual(PetMood.curious.displayName, "好奇")
        XCTAssertEqual(PetMood.sleepy.displayName, "想睡")
        XCTAssertEqual(PetMood.lonely.displayName, "寂寞")
        XCTAssertEqual(PetMood.excited.displayName, "興奮")
        XCTAssertEqual(PetMood.startled.displayName, "嚇到")
    }

    // MARK: - EvolutionRequirement

    func testEvolutionRequirementForEgg() {
        let req = EvolutionRequirement.for(.egg)
        XCTAssertNotNil(req)
        XCTAssertEqual(req?.targetLevel, .baby)
        XCTAssertEqual(req?.requiredExperience, 100)
        XCTAssertEqual(req?.socialBonus, 1.5)
        XCTAssertEqual(req?.minimumAge, 86400)
    }

    func testEvolutionRequirementForBaby() {
        let req = EvolutionRequirement.for(.baby)
        XCTAssertNotNil(req)
        XCTAssertEqual(req?.targetLevel, .adult)
        XCTAssertEqual(req?.requiredExperience, 500)
    }

    // MARK: - SocialEntry

    func testSocialEntryDefaultsToUnrevealed() {
        let entry = SocialEntry(
            partnerPetID: UUID(),
            partnerName: "Buddy",
            interaction: .greet
        )
        XCTAssertFalse(entry.isRevealed)
        XCTAssertTrue(entry.dialogue.isEmpty)
    }

    func testSocialEntryCodableRoundTrip() throws {
        let entry = SocialEntry(
            partnerPetID: UUID(),
            partnerName: "Test",
            interaction: .chat,
            dialogue: [DialogueLine(speaker: "A", text: "Hello")]
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(SocialEntry.self, from: data)
        XCTAssertEqual(decoded.id, entry.id)
        XCTAssertEqual(decoded.dialogue, entry.dialogue)
    }

    // MARK: - PetAction

    func testPetActionCodable() throws {
        let action = PetAction.zoomies
        let data = try JSONEncoder().encode(action)
        let decoded = try JSONDecoder().decode(PetAction.self, from: data)
        XCTAssertEqual(decoded, action)
    }

    // MARK: - PetLifeState

    func testLifeStateHighEnergy() {
        let state = PetLifeState.current(energy: 0.9)
        // During most hours, high energy should give active or waking or napping
        XCTAssertNotEqual(state, .sleeping)
    }

    func testLifeStateLowEnergy() {
        let state = PetLifeState.current(energy: 0.05)
        // Very low energy should result in napping or sleeping
        let expected: [PetLifeState] = [.sleeping, .napping]
        XCTAssertTrue(expected.contains(state), "Low energy state \(state) should be sleeping or napping")
    }

    // MARK: - InteractionType

    func testInteractionTypeExperienceValues() {
        XCTAssertEqual(InteractionType.tap.experienceValue, 2)
        XCTAssertEqual(InteractionType.petMeeting.experienceValue, 10)
        XCTAssertEqual(InteractionType.evolution.experienceValue, 0)
    }
}
