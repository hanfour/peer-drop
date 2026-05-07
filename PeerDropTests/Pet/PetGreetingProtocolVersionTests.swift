import XCTest
@testable import PeerDrop

/// Locks the M6.2 protocol-version negotiation: v4.0 senders self-tag with
/// `currentProtocolVersion`; receivers treat missing version as v1 (legacy).
/// v4.0-only PetLevel cases (.elder) are downgraded to .adult before
/// wire-encoding for a v1 peer so the frame round-trips.
final class PetGreetingProtocolVersionTests: XCTestCase {

    private func sampleGenome() -> PetGenome {
        var g = PetGenome.random()
        g.body = .cat
        g.subVariety = "tabby"
        return g
    }

    // MARK: - sender self-tags as currentProtocolVersion

    func test_freshGreeting_protocolVersionDefaults_toCurrent() {
        let g = PetGreeting(
            petID: UUID(),
            name: "x",
            level: .baby,
            mood: .happy,
            genome: sampleGenome()
        )
        XCTAssertEqual(g.protocolVersion, PetGreeting.currentProtocolVersion)
        XCTAssertEqual(g.effectiveProtocolVersion, PetGreeting.currentProtocolVersion)
    }

    func test_encodedGreeting_carries_currentProtocolVersion() throws {
        let g = PetGreeting(
            petID: UUID(),
            name: "x",
            level: .adult,
            mood: .happy,
            genome: sampleGenome()
        )
        let json = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(g)) as! [String: Any]
        XCTAssertEqual(json["protocolVersion"] as? Int, PetGreeting.currentProtocolVersion)
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

    // MARK: - downgraded() — v1 receiver path

    func test_downgraded_toV1_elder_becomes_adult() {
        let elder = PetGreeting(
            petID: UUID(),
            name: nil,
            level: .elder,
            mood: .sleepy,
            genome: sampleGenome()
        )
        let downgraded = elder.downgraded(toProtocolVersion: 1)
        XCTAssertEqual(downgraded.level, .adult)
        XCTAssertEqual(downgraded.petID, elder.petID)
        XCTAssertEqual(downgraded.mood, elder.mood)
        XCTAssertEqual(downgraded.genome.body, elder.genome.body)
    }

    func test_downgraded_toV1_nonElder_unchanged() {
        for stage in [PetLevel.baby, .adult] {
            let g = PetGreeting(
                petID: UUID(),
                name: nil,
                level: stage,
                mood: .happy,
                genome: sampleGenome()
            )
            let downgraded = g.downgraded(toProtocolVersion: 1)
            XCTAssertEqual(downgraded.level, stage, "\(stage) should pass through unchanged")
        }
    }

    func test_downgraded_toCurrentVersion_elder_unchanged() {
        let elder = PetGreeting(
            petID: UUID(),
            name: nil,
            level: .elder,
            mood: .sleepy,
            genome: sampleGenome()
        )
        let downgraded = elder.downgraded(toProtocolVersion: PetGreeting.currentProtocolVersion)
        XCTAssertEqual(downgraded.level, .elder, "same-version peer should receive .elder unchanged")
    }

    // MARK: - end-to-end: v4.0 sender → simulated v3.x receiver via downgrade

    func test_downgraded_v4Elder_serialised_decodesOnSimulatedV3xReceiver() throws {
        // Simulate a v3.x receiver via a stripped-down enum + struct pair.
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
        // Direct encode would emit level=4 — v3.x fails. Downgrade first.
        let downgraded = elder.downgraded(toProtocolVersion: 1)
        let data = try JSONEncoder().encode(downgraded)
        let decoded = try JSONDecoder().decode(V3xGreeting.self, from: data)
        XCTAssertEqual(decoded.level, .child, "downgraded .adult lands as v3.x .child via shared rawValue=3")
    }

    // MARK: - v4 ↔ v4 happy path: full round-trip preserves elder

    func test_v4ToV4_elder_roundTripsUnchanged() throws {
        var genome = PetGenome.random()
        genome.body = .cat
        genome.subVariety = "tabby"
        genome.seed = 42
        let original = PetGreeting(
            petID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            name: "v4-elder",
            level: .elder,
            mood: .lonely,
            genome: genome
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PetGreeting.self, from: data)
        XCTAssertEqual(decoded.level, .elder)
        XCTAssertEqual(decoded.protocolVersion, PetGreeting.currentProtocolVersion)
        XCTAssertEqual(decoded.genome.subVariety, "tabby")
        XCTAssertEqual(decoded.genome.seed, 42)
    }

    // MARK: - v5+ peer: simulated newer-than-self decode

    func test_v5xGreeting_simulated_decodesAsV4_orFailsGracefully() throws {
        // A hypothetical v5+ peer might tag itself with protocolVersion: 5 and
        // could ship genome fields v4 doesn't know about. v4's decoder must
        // either decode the v4-known parts cleanly (ignoring v5-only keys) OR
        // throw — never crash silently.
        let v5JSON = """
        {
          "petID": "55555555-5555-5555-5555-555555555555",
          "name": "future-pet",
          "level": 4,
          "mood": "happy",
          "genome": {
            "body": "cat",
            "eyes": "dot",
            "pattern": "none",
            "personalityGene": 0.5,
            "subVariety": "tabby",
            "seed": 100,
            "v5OnlyField": "ignored-by-v4"
          },
          "protocolVersion": 5,
          "v5RootField": ["unknown", "to", "v4"]
        }
        """.data(using: .utf8)!

        let g = try JSONDecoder().decode(PetGreeting.self, from: v5JSON)
        XCTAssertEqual(g.protocolVersion, 5,
                       "v4 records peer's higher version — no automatic downgrade on receive")
        XCTAssertEqual(g.effectiveProtocolVersion, 5)
        XCTAssertEqual(g.level, .elder, "level=4 still decodes as .elder; v5 may add 5+ later")
        XCTAssertEqual(g.genome.subVariety, "tabby")
        // v4 doesn't have a downgrade FROM higher versions — out of scope until
        // v5 actually exists. Receiver-side v5 handling is a future commit.
    }

    // MARK: - decode-then-re-encode preserves byte-shape (no spurious null)

    func test_v3xJSON_decodedAndReEncoded_doesNotEmitNullProtocolVersion() throws {
        let v3xJSON = """
        {
          "petID": "66666666-6666-6666-6666-666666666666",
          "name": null,
          "level": 3,
          "mood": "curious",
          "genome": { "body": "dog", "eyes": "round", "pattern": "none", "personalityGene": 0.1 }
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(PetGreeting.self, from: v3xJSON)
        XCTAssertNil(decoded.protocolVersion)

        let reEncoded = try JSONEncoder().encode(decoded)
        let reJSON = try JSONSerialization.jsonObject(with: reEncoded) as! [String: Any]
        XCTAssertNil(reJSON["protocolVersion"],
                     "re-encoded greeting from v3.x should not introduce a null protocolVersion key")
    }
}
