import XCTest
@testable import PeerDrop

final class PetSocialEngineTests: XCTestCase {

    private var engine: PetSocialEngine!

    override func setUp() {
        super.setUp()
        engine = PetSocialEngine()
    }

    // MARK: - Helpers

    private func makePet(mood: PetMood = .happy, socialLog: [SocialEntry] = []) -> PetState {
        PetState(
            id: UUID(),
            name: "TestPet",
            birthDate: Date(),
            level: .baby,
            experience: 10,
            genome: .random(),
            mood: mood,
            socialLog: socialLog,
            lastInteraction: Date()
        )
    }

    private func makeGreeting(name: String? = "PartnerPet") -> PetGreeting {
        PetGreeting(
            petID: UUID(),
            name: name,
            level: .baby,
            mood: .curious,
            genome: .random()
        )
    }

    // MARK: - onPetMeeting

    func testOnPetMeetingCreatesSocialEntry() {
        let myPet = makePet()
        let greeting = makeGreeting()

        let entry = engine.onPetMeeting(myPet: myPet, partnerGreeting: greeting)

        XCTAssertEqual(entry.partnerPetID, greeting.petID)
        XCTAssertEqual(entry.partnerName, greeting.name)
        XCTAssertFalse(entry.isRevealed)
        XCTAssertFalse(entry.dialogue.isEmpty, "Dialogue should not be empty")
    }

    // MARK: - tryReveal

    func testTryRevealRequiresHappyMood() {
        let unrevealed = SocialEntry(
            partnerPetID: UUID(),
            partnerName: "Other",
            interaction: .chat,
            dialogue: [DialogueLine(speaker: "mine", text: "嘿！")],
            isRevealed: false
        )
        let pet = makePet(mood: .sleepy, socialLog: [unrevealed])

        // Even with unrevealed entries, sleepy mood should always return nil
        for _ in 0..<100 {
            XCTAssertNil(engine.tryReveal(pet: pet))
        }
    }

    func testTryRevealReturnsNilWhenAllRevealed() {
        let revealed = SocialEntry(
            partnerPetID: UUID(),
            partnerName: "Other",
            interaction: .chat,
            dialogue: [DialogueLine(speaker: "mine", text: "嘿！")],
            isRevealed: true
        )
        let pet = makePet(mood: .happy, socialLog: [revealed])

        // Happy mood but all entries already revealed — should always return nil
        for _ in 0..<100 {
            XCTAssertNil(engine.tryReveal(pet: pet))
        }
    }

    func testTryRevealCanSucceedWhenHappy() {
        let unrevealed = SocialEntry(
            partnerPetID: UUID(),
            partnerName: "Other",
            interaction: .chat,
            dialogue: [DialogueLine(speaker: "mine", text: "嘿！")],
            isRevealed: false
        )
        let pet = makePet(mood: .happy, socialLog: [unrevealed])

        // 30 % chance per try — over 100 attempts, should succeed at least once
        var succeeded = false
        for _ in 0..<100 {
            if let result = engine.tryReveal(pet: pet) {
                XCTAssertTrue(result.isRevealed)
                XCTAssertEqual(result.partnerPetID, unrevealed.partnerPetID)
                succeeded = true
                break
            }
        }
        XCTAssertTrue(succeeded, "tryReveal should succeed at least once in 100 attempts with 30% chance")
    }
}
