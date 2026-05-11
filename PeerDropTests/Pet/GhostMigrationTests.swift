import XCTest
@testable import PeerDrop

/// Pins the v5.0.1 ghost retirement contract:
///   • BodyGene decoder maps `body: "ghost"` (legacy persistence) → .cat
///   • Cross-version peer payloads carrying body=ghost decode without crashing
///   • Single-value Codable contract still works for non-ghost bodies
@MainActor
final class GhostMigrationTests: XCTestCase {

    // MARK: - decoder migration: "ghost" → .cat

    func test_bodyGeneDecoder_mapsGhostString_toCat() throws {
        let json = "\"ghost\"".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(BodyGene.self, from: json)
        XCTAssertEqual(decoded, .cat)
    }

    func test_bodyGeneDecoder_preservesCanonicalBodies() throws {
        for body in BodyGene.allCases {
            let json = "\"\(body.rawValue)\"".data(using: .utf8)!
            let decoded = try JSONDecoder().decode(BodyGene.self, from: json)
            XCTAssertEqual(decoded, body, "Round-trip failed for \(body.rawValue)")
        }
    }

    func test_bodyGeneDecoder_preservesV1LegacyShapes() throws {
        // v1 genome shape names persisted before BodyGene flattened to species.
        // The decoder still maps these for users coming from very old installs.
        let cases: [(String, BodyGene)] = [
            ("round", .bear),
            ("square", .cat),
            ("oval", .slime),
        ]
        for (raw, expected) in cases {
            let json = "\"\(raw)\"".data(using: .utf8)!
            let decoded = try JSONDecoder().decode(BodyGene.self, from: json)
            XCTAssertEqual(decoded, expected, "Legacy '\(raw)' should map to \(expected)")
        }
    }

    func test_bodyGeneDecoder_throwsOnGenuinelyUnknownString() {
        let json = "\"phoenix\"".data(using: .utf8)!  // not a BodyGene case
        XCTAssertThrowsError(try JSONDecoder().decode(BodyGene.self, from: json))
    }

    // MARK: - PetState round-trip with ghost body in JSON

    func test_petStateDecode_withGhostBodyJSON_yieldsCatBody() throws {
        let petJSON = """
        {
            "schemaVersion": 2,
            "id": "9D63B2E8-1D2C-4E61-9F44-2F7E94BFEFFA",
            "birthDate": -3000000,
            "level": 2,
            "experience": 100,
            "genome": {
                "body": "ghost",
                "eyes": "round",
                "pattern": "none",
                "personalityGene": 0.42
            },
            "mood": "happy",
            "socialLog": [],
            "lastInteraction": 0
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let pet = try decoder.decode(PetState.self, from: petJSON)
        XCTAssertEqual(pet.genome.body, .cat,
                       "Persisted body=ghost should silently migrate to .cat")
        // Identity preserved
        XCTAssertEqual(pet.id.uuidString, "9D63B2E8-1D2C-4E61-9F44-2F7E94BFEFFA")
        XCTAssertEqual(pet.experience, 100)
        XCTAssertEqual(pet.mood, .happy)
    }

    // MARK: - Genome distribution: no .ghost ever produced

    func test_bodyGeneFrom_neverReturnsGhost_acrossWideRange() {
        // BodyGene.from spans the unit interval; sample densely so any
        // residual ghost band would surface.
        for i in 0..<10_000 {
            let pg = Double(i) / 10_000.0
            let body = BodyGene.from(personalityGene: pg)
            XCTAssertNotNil(BodyGene.allCases.firstIndex(of: body),
                            "BodyGene.from(\(pg)) returned out-of-enum value \(body)")
            // No raw equality with .ghost because the case was removed; the
            // canon is "no allCases member is named ghost". Re-affirm:
            XCTAssertNotEqual(body.rawValue, "ghost",
                              "BodyGene.from(\(pg)) returned a ghost rawValue — distribution not migrated")
        }
    }

    // MARK: - PetEngine.migrateGhostBodyForV501 contract

    func test_migrateGhostBodyForV501_persistsCurrentState() {
        let pet = PetState.newEgg()
        let engine = PetEngine(pet: pet)
        let result = engine.migrateGhostBodyForV501()
        XCTAssertTrue(result, "Migration should succeed and return true")
    }
}
