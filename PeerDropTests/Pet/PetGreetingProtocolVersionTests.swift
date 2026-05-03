import XCTest
@testable import PeerDrop

/// Locks the M6.2 protocol-version negotiation: v4.0 senders self-tag with
/// version 2; receivers treat missing version as v1 (legacy). v4.0-only
/// PetLevel cases (.elder) are clamped down to .adult before wire-encoding
/// for a v1 peer so the frame round-trips.
final class PetGreetingProtocolVersionTests: XCTestCase {

    private func sampleGenome() -> PetGenome {
        var g = PetGenome.random()
        g.body = .cat
        g.subVariety = "tabby"
        return g
    }

    // MARK: - sender self-tags as v2

    func test_freshGreeting_protocolVersionDefaults_to2() {
        let g = PetGreeting(
            petID: UUID(),
            name: "x",
            level: .baby,
            mood: .happy,
            genome: sampleGenome()
        )
        XCTAssertEqual(g.protocolVersion, 2)
        XCTAssertEqual(g.effectiveProtocolVersion, 2)
    }

    func test_encodedGreeting_carries_protocolVersion2() throws {
        let g = PetGreeting(
            petID: UUID(),
            name: "x",
            level: .adult,
            mood: .happy,
            genome: sampleGenome()
        )
        let json = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(g)) as! [String: Any]
        XCTAssertEqual(json["protocolVersion"] as? Int, 2)
    }

    // MARK: - receiver: missing version → treated as v1

    func test_v3xGreeting_withoutProtocolVersion_decodes_andDefaultsTo_v1() throws {
        let v3xJSON = """
        {
          "petID": "11111111-1111-1111-1111-111111111111",
          "name": "old-pet",
          "level": 3,
          "mood": "happy",
          "genome": { "body": "cat", "eyes": "dot", "pattern": "none", "personalityGene": 0.5 }
        }
        """.data(using: .utf8)!

        let g = try JSONDecoder().decode(PetGreeting.self, from: v3xJSON)
        XCTAssertNil(g.protocolVersion, "v3.x JSON has no protocolVersion key")
        XCTAssertEqual(g.effectiveProtocolVersion, 1, "missing version maps to v1")
    }

    // MARK: - clamping for v1 peers

    func test_clampedForV1_elder_becomes_adult() {
        let elder = PetGreeting(
            petID: UUID(),
            name: nil,
            level: .elder,
            mood: .sleepy,
            genome: sampleGenome()
        )
        let clamped = elder.clamped(forPeerProtocolVersion: 1)
        XCTAssertEqual(clamped.level, .adult)
        // Other fields preserved.
        XCTAssertEqual(clamped.petID, elder.petID)
        XCTAssertEqual(clamped.mood, elder.mood)
        XCTAssertEqual(clamped.genome.body, elder.genome.body)
    }

    func test_clampedForV1_nonElder_unchanged() {
        for stage in [PetLevel.egg, .baby, .adult] {
            let g = PetGreeting(
                petID: UUID(),
                name: nil,
                level: stage,
                mood: .happy,
                genome: sampleGenome()
            )
            let clamped = g.clamped(forPeerProtocolVersion: 1)
            XCTAssertEqual(clamped.level, stage, "\(stage) should pass through unchanged")
        }
    }

    func test_clampedForV2_elder_unchanged() {
        let elder = PetGreeting(
            petID: UUID(),
            name: nil,
            level: .elder,
            mood: .sleepy,
            genome: sampleGenome()
        )
        let clamped = elder.clamped(forPeerProtocolVersion: 2)
        XCTAssertEqual(clamped.level, .elder, "v2+ peer should receive .elder unchanged")
    }

    // MARK: - end-to-end: v4.0 sender → v1 receiver via clamp

    func test_clampedV4Elder_serialised_decodesOnSimulatedV3xReceiver() throws {
        // Simulate a v3.x receiver via a stripped-down enum.
        enum V3xPetLevel: Int, Codable { case egg = 1, baby = 2, child = 3 }
        struct V3xGenome: Codable {
            let body: String
            let eyes: String
            let pattern: String
            let personalityGene: Double
        }
        struct V3xGreeting: Codable {
            let petID: UUID
            let name: String?
            let level: V3xPetLevel
            let mood: String
            let genome: V3xGenome
        }

        let elder = PetGreeting(
            petID: UUID(),
            name: "v4pet",
            level: .elder,
            mood: .lonely,
            genome: sampleGenome()
        )
        // Direct encode would emit level=4 — v3.x fails. Clamp first.
        let clamped = elder.clamped(forPeerProtocolVersion: 1)
        let data = try JSONEncoder().encode(clamped)
        let decoded = try JSONDecoder().decode(V3xGreeting.self, from: data)
        XCTAssertEqual(decoded.level, .child, "clamped .adult lands as v3.x .child via shared rawValue=3")
    }
}
