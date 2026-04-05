import XCTest
@testable import PeerDrop

final class PetPayloadTests: XCTestCase {

    private func makeGenome() -> PetGenome {
        PetGenome(body: .round, eyes: .dot, limbs: .short, pattern: .none, personalityGene: 0.5)
    }

    // MARK: - PetGreeting Codable

    func testPetGreetingCodable() throws {
        let greeting = PetGreeting(
            petID: UUID(),
            name: "Pixel",
            level: .baby,
            mood: .happy,
            genome: makeGenome()
        )

        let data = try JSONEncoder().encode(greeting)
        let decoded = try JSONDecoder().decode(PetGreeting.self, from: data)

        XCTAssertEqual(decoded.petID, greeting.petID)
        XCTAssertEqual(decoded.name, "Pixel")
        XCTAssertEqual(decoded.level, .baby)
        XCTAssertEqual(decoded.mood, .happy)
    }

    // MARK: - PetPayload Greeting

    func testPetPayloadGreeting() throws {
        let greeting = PetGreeting(
            petID: UUID(),
            name: "Buddy",
            level: .egg,
            mood: .curious,
            genome: makeGenome()
        )

        let payload = try PetPayload.greeting(greeting)
        XCTAssertEqual(payload.type, .greeting)

        let decoded = try payload.decodeGreeting()
        XCTAssertEqual(decoded.petID, greeting.petID)
        XCTAssertEqual(decoded.name, "Buddy")
    }

    // MARK: - PetPayload SocialChat

    func testPetPayloadSocialChat() throws {
        let lines: [DialogueLine] = [
            DialogueLine(speaker: "Pixel", text: "Hello!"),
            DialogueLine(speaker: "Buddy", text: "Hi there!")
        ]

        let payload = try PetPayload.socialChat(lines)
        XCTAssertEqual(payload.type, .socialChat)

        let decoded = try payload.decodeDialogue()
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].speaker, "Pixel")
        XCTAssertEqual(decoded[1].text, "Hi there!")
    }

    // MARK: - PetPayload Reaction

    func testPetPayloadReaction() throws {
        let payload = try PetPayload.reaction(.wagTail)
        XCTAssertEqual(payload.type, .reaction)

        let decoded = try payload.decodeReaction()
        XCTAssertEqual(decoded, .wagTail)
    }

    // MARK: - PetPayload Round-trip Codable

    func testPetPayloadCodable() throws {
        let greeting = PetGreeting(
            petID: UUID(),
            name: nil,
            level: .egg,
            mood: .sleepy,
            genome: makeGenome()
        )

        let original = try PetPayload.greeting(greeting)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PetPayload.self, from: encoded)

        XCTAssertEqual(decoded.type, .greeting)
        let decodedGreeting = try decoded.decodeGreeting()
        XCTAssertEqual(decodedGreeting.petID, greeting.petID)
        XCTAssertNil(decodedGreeting.name)
    }
}
