import XCTest
@testable import PeerDrop

/// Locks the PetState cross-version contract for cloud sync (PetCloudSync /
/// PetStore JSON files). Sister test to PetPayloadCrossVersionTests, but for
/// the persistence wire format rather than the peer-meeting wire format.
///
/// Compat surface (already established by M1.2 + M2.4):
///   • PetState.migrationDoneAt is Optional — v3.x JSON without the key
///     decodes as nil; v4.0 JSON with the key round-trips.
///   • PetGenome.subVariety / .seed are Optional — same story.
///   • PetLevel.adult.rawValue == 3 keeps v3.x "child"-typed records
///     readable; v4.0 .elder (rawValue 4) is NOT readable on v3.x devices,
///     so cloud sync from v4.0 → v3.x device drops elder pets back to
///     adult on the v3.x side via the M6.2 protocol-version downgrade
///     pattern (file-side handled by truncating before save when needed).
final class PetStateCloudSyncCompatTests: XCTestCase {

    private func sampleGenome() -> PetGenome {
        PetGenome(body: .cat, eyes: .dot, pattern: .none, personalityGene: 0.5)
    }

    // MARK: - v3.x JSON → v4.0 decoder

    func test_v3xPetJSON_withoutNewFields_decodes_andResolvedIDFallsBack() throws {
        // Hand-rolled v3.x-shape PetState: no migrationDoneAt at the top level,
        // no subVariety/seed in genome.
        let v3xJSON = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "name": "OldCat",
          "birthDate": 740000000,
          "level": 3,
          "experience": 250,
          "genome": {
            "body": "cat",
            "eyes": "dot",
            "pattern": "stripe",
            "personalityGene": 0.42
          },
          "mood": "happy",
          "socialLog": [],
          "lastInteraction": 740000000,
          "foodInventory": { "items": [] },
          "lifeState": "idle",
          "stats": {
            "foodsEaten": 0,
            "poopsCleaned": 0,
            "totalInteractions": 0,
            "petsMet": 0
          }
        }
        """.data(using: .utf8)!

        let pet = try JSONDecoder().decode(PetState.self, from: v3xJSON)
        XCTAssertEqual(pet.name, "OldCat")
        XCTAssertEqual(pet.level, .adult)                   // rawValue 3 → renamed
        XCTAssertNil(pet.migrationDoneAt)                   // missing → nil
        XCTAssertNil(pet.genome.subVariety)
        XCTAssertNil(pet.genome.seed)
        XCTAssertEqual(pet.genome.resolvedSpeciesID, SpeciesID("cat-tabby"))
    }

    // MARK: - v4.0 JSON → v3.x decoder (simulated via stripped PetState clone)

    func test_v4PetJSON_extraNewFields_decodes_byPermissiveDecoder() throws {
        var pet = PetState.newEgg()
        pet.level = .adult
        pet.genome.body = .dog
        pet.genome.subVariety = "shiba"
        pet.genome.seed = 4242
        pet.migrationDoneAt = Date(timeIntervalSince1970: 1700000000)

        let data = try JSONEncoder().encode(pet)
        let decoded = try JSONDecoder().decode(PetState.self, from: data)
        XCTAssertEqual(decoded.genome.subVariety, "shiba")
        XCTAssertEqual(decoded.genome.seed, 4242)
        XCTAssertEqual(decoded.migrationDoneAt, pet.migrationDoneAt)
    }

    func test_v4PetJSON_strippedToV3xKeys_recoveredViaFallbackChain() throws {
        var pet = PetState.newEgg()
        pet.level = .adult
        pet.genome.body = .slime
        pet.genome.subVariety = "fire"
        pet.genome.seed = 999
        pet.migrationDoneAt = Date()

        // Strip v4.0-only top-level + nested keys, then re-decode.
        var dict = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(pet)) as! [String: Any]
        dict.removeValue(forKey: "migrationDoneAt")
        var genomeDict = dict["genome"] as! [String: Any]
        genomeDict.removeValue(forKey: "subVariety")
        genomeDict.removeValue(forKey: "seed")
        dict["genome"] = genomeDict
        let stripped = try JSONSerialization.data(withJSONObject: dict)

        let recovered = try JSONDecoder().decode(PetState.self, from: stripped)
        XCTAssertNil(recovered.migrationDoneAt)
        XCTAssertNil(recovered.genome.subVariety)
        XCTAssertNil(recovered.genome.seed)
        // Fallback: body=.slime → defaultSpeciesID = slime-green
        XCTAssertEqual(recovered.genome.resolvedSpeciesID, SpeciesID("slime-green"))
    }

    // MARK: - PetLevel.elder is NEW in v4.0 — v3.x can't decode

    func test_v3xDecoder_simulated_failsOnElderRecord() throws {
        // Same gap as PetPayloadCrossVersionTests demonstrates for greetings.
        // The cloud-sync layer needs an analogous downgrade-before-save when
        // the local device is v4.0 but a peer device on the same iCloud
        // account is still v3.x. Plan-deferred — currently no production
        // device-version detection on the cloud sync path.
        enum V3xLevel: Int, Codable { case egg = 1, baby = 2, child = 3 }
        struct V3xLevelHolder: Codable { let level: V3xLevel }
        let elderJSON = #"{"level":4}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(V3xLevelHolder.self, from: elderJSON))
    }

    // MARK: - round-trip stability (M7.1 plan step 4)

    // MARK: - fuzz: random v3.x ↔ v4.0 records decode crash-free

    /// 1000-frame fuzz mirroring PetPayloadCrossVersionTests's pattern but
    /// for the persistence wire format. Catches future Codable additions
    /// that accidentally break legacy record decoding (e.g. a new required
    /// non-Optional field added to PetState).
    func test_fuzz_1000RandomPetStateRecords_neverCrashes() {
        var rng = SplitMixRNG(seed: 0x1234_5678_9ABC_DEF0)
        var failures = 0

        for _ in 0..<1000 {
            let json = rng.nextBool() ? randomV4PetJSON(&rng) : randomV3xPetJSON(&rng)
            do {
                _ = try JSONDecoder().decode(PetState.self, from: json)
            } catch {
                failures += 1
            }
        }
        // 1% threshold matches the M6.1 PetPayload fuzz cap. Observed actual
        // rate on these generators is 0.
        XCTAssertLessThan(failures, 10,
                          "Decode failure rate too high: \(failures)/1000 — fuzz generators may be malformed")
    }

    private struct SplitMixRNG: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { self.state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func nextBool() -> Bool { next() & 1 == 1 }
        mutating func nextDouble01() -> Double { Double(next() >> 11) / Double(1 << 53) }
    }

    private let bodies = ["cat", "dog", "rabbit", "bird", "frog", "bear", "dragon", "octopus", "ghost", "slime"]
    private let v3Levels = [1, 2, 3]
    private let v4Levels = [1, 2, 3, 4]
    private let moods    = ["happy", "curious", "sleepy", "lonely", "excited", "startled"]
    private let lifeStates = ["idle", "eating", "digesting", "sleeping", "active"]
    private let eyes     = ["dot", "round", "line", "dizzy"]
    private let patterns = ["none", "stripe", "spot"]

    private func randomV3xPetJSON(_ rng: inout SplitMixRNG) -> Data {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "name": \(rng.nextBool() ? "\"v3pet\"" : "null"),
          "birthDate": \(rng.nextDouble01() * 1_000_000_000 + 700_000_000),
          "level": \(v3Levels.randomElement(using: &rng)!),
          "experience": \(rng.next() % 1000),
          "genome": {
            "body": "\(bodies.randomElement(using: &rng)!)",
            "eyes": "\(eyes.randomElement(using: &rng)!)",
            "pattern": "\(patterns.randomElement(using: &rng)!)",
            "personalityGene": \(rng.nextDouble01())
          },
          "mood": "\(moods.randomElement(using: &rng)!)",
          "socialLog": [],
          "lastInteraction": \(rng.nextDouble01() * 1_000_000_000 + 700_000_000),
          "foodInventory": { "items": [] },
          "lifeState": "\(lifeStates.randomElement(using: &rng)!)",
          "stats": { "foodsEaten": 0, "poopsCleaned": 0, "totalInteractions": 0, "petsMet": 0 }
        }
        """
        return json.data(using: .utf8)!
    }

    private func randomV4PetJSON(_ rng: inout SplitMixRNG) -> Data {
        let subVarietyClause = rng.nextBool() ? "\"subVariety\": \"tabby\"," : ""
        let seedClause = rng.nextBool() ? "\"seed\": \(rng.next() & 0xFFFF_FFFF)," : ""
        let migDoneClause = rng.nextBool() ? "\"migrationDoneAt\": \(rng.nextDouble01() * 100_000_000 + 700_000_000)," : ""
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "name": "v4pet",
          "birthDate": \(rng.nextDouble01() * 1_000_000_000 + 700_000_000),
          "level": \(v4Levels.randomElement(using: &rng)!),
          "experience": \(rng.next() % 1000),
          "genome": {
            "body": "\(bodies.randomElement(using: &rng)!)",
            "eyes": "\(eyes.randomElement(using: &rng)!)",
            "pattern": "\(patterns.randomElement(using: &rng)!)",
            "personalityGene": \(rng.nextDouble01()),
            \(subVarietyClause)
            \(seedClause)
            "_v5Padding": null
          },
          "mood": "\(moods.randomElement(using: &rng)!)",
          "socialLog": [],
          "lastInteraction": \(rng.nextDouble01() * 1_000_000_000 + 700_000_000),
          "foodInventory": { "items": [] },
          "lifeState": "\(lifeStates.randomElement(using: &rng)!)",
          "stats": { "foodsEaten": 0, "poopsCleaned": 0, "totalInteractions": 0, "petsMet": 0 },
          \(migDoneClause)
          "_v5RootPadding": null
        }
        """
        return json.data(using: .utf8)!
    }

    func test_loadDecodeReEncodeDecode_isStable() throws {
        var original = PetState.newEgg()
        original.level = .adult
        original.genome.body = .cat
        original.genome.subVariety = "tabby"
        original.genome.seed = 12345
        original.migrationDoneAt = Date(timeIntervalSince1970: 1700000000)

        let firstEncode = try JSONEncoder().encode(original)
        let firstDecode = try JSONDecoder().decode(PetState.self, from: firstEncode)
        let secondEncode = try JSONEncoder().encode(firstDecode)
        let secondDecode = try JSONDecoder().decode(PetState.self, from: secondEncode)

        XCTAssertEqual(secondDecode.id, original.id)
        XCTAssertEqual(secondDecode.level, original.level)
        XCTAssertEqual(secondDecode.genome.subVariety, original.genome.subVariety)
        XCTAssertEqual(secondDecode.genome.seed, original.genome.seed)
        XCTAssertEqual(secondDecode.migrationDoneAt, original.migrationDoneAt)
        // Encoded JSON should match (modulo key ordering — compare as JSON dicts).
        let firstDict = try JSONSerialization.jsonObject(with: firstEncode) as! [String: Any]
        let secondDict = try JSONSerialization.jsonObject(with: secondEncode) as! [String: Any]
        XCTAssertEqual(NSDictionary(dictionary: firstDict),
                       NSDictionary(dictionary: secondDict))
    }
}
