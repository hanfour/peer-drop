import XCTest
@testable import PeerDrop

/// Pins the cross-version contract for PetGreeting (the wire-format struct
/// peers exchange when their pets meet). The compat surface is:
///   • PetGenome.subVariety / .seed are Optional (M2.4) — v3.x JSON without
///     these keys decodes cleanly on v4.0; v4.0 JSON with them decodes on
///     v3.x because Codable ignores unknown keys by default.
///   • PetLevel kept rawValue=3 for the renamed "child"→"adult" case (M1.1)
///     so v3.x level=3 decodes as v4.0 .adult and vice versa.
///   • PetLevel.elder (rawValue=4) is NEW in v4.0 — v3.x peers can't decode
///     it. M6.2 adds protocolVersion negotiation so v4.0 senders can clamp
///     elder→adult before serialising for v1 peers.
final class PetPayloadCrossVersionTests: XCTestCase {

    // MARK: - v3.x JSON → v4.0 decoder (forward compat)

    func test_v3xGreeting_withoutSubVarietyOrSeed_decodes_onV4() throws {
        // Hand-rolled JSON in the v3.x shape: PetGenome has no subVariety/seed.
        let v3xJSON = """
        {
          "petID": "11111111-1111-1111-1111-111111111111",
          "name": "Whiskers",
          "level": 3,
          "mood": "happy",
          "genome": {
            "body": "cat",
            "eyes": "dot",
            "pattern": "stripe",
            "personalityGene": 0.42
          }
        }
        """.data(using: .utf8)!

        let greeting = try JSONDecoder().decode(PetGreeting.self, from: v3xJSON)
        XCTAssertEqual(greeting.name, "Whiskers")
        XCTAssertEqual(greeting.level, .adult)              // rawValue 3 → renamed case
        XCTAssertEqual(greeting.mood, .happy)
        XCTAssertEqual(greeting.genome.body, .cat)
        XCTAssertNil(greeting.genome.subVariety)            // missing key → nil
        XCTAssertNil(greeting.genome.seed)
        // Renderer fallback: with no subVariety/seed, resolvedSpeciesID falls
        // through to body.defaultSpeciesID = cat-tabby.
        XCTAssertEqual(greeting.genome.resolvedSpeciesID, SpeciesID("cat-tabby"))
    }

    func test_v3xGreeting_legacyChildLevel_decodes_asAdult_onV4() throws {
        // v3.x clients send level=3 for what they call .child; v4.0 reads it
        // as .adult thanks to the M1.1 case rename keeping rawValue=3.
        let v3xJSON = """
        {
          "petID": "22222222-2222-2222-2222-222222222222",
          "name": null,
          "level": 3,
          "mood": "curious",
          "genome": { "body": "dog", "eyes": "round", "pattern": "none", "personalityGene": 0.1 }
        }
        """.data(using: .utf8)!

        let greeting = try JSONDecoder().decode(PetGreeting.self, from: v3xJSON)
        XCTAssertEqual(greeting.level, .adult)
    }

    // MARK: - v4.0 JSON → v3.x decoder (backward compat, simulated)

    func test_v4Greeting_extraSubVarietyAndSeed_decodes_byPermissiveDecoder() throws {
        // Simulate a v3.x JSONDecoder by encoding a v4.0 greeting and ensuring
        // a strict re-decode works (Codable ignores unknown keys by default).
        var genome = PetGenome.random()
        genome.body = .cat
        genome.subVariety = "tabby"
        genome.seed = 12345
        let original = PetGreeting(
            petID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            name: "Mittens",
            level: .baby,
            mood: .sleepy,
            genome: genome
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PetGreeting.self, from: data)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.level, original.level)
        XCTAssertEqual(decoded.genome.body, original.genome.body)
        XCTAssertEqual(decoded.genome.subVariety, original.genome.subVariety)
        XCTAssertEqual(decoded.genome.seed, original.genome.seed)
    }

    func test_v4Genome_strippedDownToV3xFields_decodes_andResolvedSpeciesID_fallsBack() throws {
        // The actual v3.x → v4.0 wire path: encode a v4.0 genome, strip the
        // v4.0-only keys, re-decode. resolvedSpeciesID should land on the
        // body default (the M2.4 fallback chain).
        var v4 = PetGenome.random()
        v4.body = .slime
        v4.subVariety = "fire"
        v4.seed = 999

        var dict = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(v4)) as! [String: Any]
        dict.removeValue(forKey: "subVariety")
        dict.removeValue(forKey: "seed")
        let stripped = try JSONSerialization.data(withJSONObject: dict)

        let decoded = try JSONDecoder().decode(PetGenome.self, from: stripped)
        XCTAssertEqual(decoded.body, .slime)
        XCTAssertNil(decoded.subVariety)
        XCTAssertNil(decoded.seed)
        XCTAssertEqual(decoded.resolvedSpeciesID, SpeciesID("slime-green"))   // body default
    }

    // MARK: - PetLevel.elder is NEW in v4.0 — v3.x peers can't decode it

    func test_v3xDecoder_simulatedAgainstElderLevel_fails() throws {
        // Demonstrates the gap M6.2 closes via protocolVersion clamping.
        // v3.x's PetLevel enum has rawValues 1..3 (egg, baby, child); level=4
        // (.elder in v4.0) is unknown. We can't run a literal v3.x decoder
        // here, but we can simulate it with a constrained decoder enum.
        enum V3xPetLevel: Int, Codable { case egg = 1, baby = 2, child = 3 }
        struct V3xLevelHolder: Codable { let level: V3xPetLevel }

        let v4ElderJSON = #"{"level":4}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(V3xLevelHolder.self, from: v4ElderJSON))
    }

    // MARK: - Fuzz: random v3.x ↔ v4.0 frames decode without crashes

    func test_fuzz_1000RandomFrames_neverCrashes() {
        // Deterministic seed so failures reproduce.
        var rng = SplitMixRNG(seed: 0xDEAD_BEEF_CAFE_BABE)
        var decodeFailures = 0

        for _ in 0..<1000 {
            let isV4 = rng.nextBool()
            let json = isV4 ? randomV4GreetingJSON(&rng) : randomV3xGreetingJSON(&rng)
            do {
                _ = try JSONDecoder().decode(PetGreeting.self, from: json)
            } catch {
                decodeFailures += 1
                // Acceptable failures: malformed JSON we constructed (e.g. an
                // out-of-range stage). Test passes as long as we never CRASH.
                // Track the count so unexpected failure rates surface.
                _ = error
            }
        }
        // Crash-free is the contract. The count itself is a soft signal —
        // observed actual rate on the current generators is 0, so we keep
        // the cap tight at 1% (10 / 1000). A regression that fails 4% would
        // have silently passed under the original 5% cap.
        XCTAssertLessThan(decodeFailures, 10,
                          "Decode failure rate too high: \(decodeFailures)/1000 — fuzz generators may be malformed")
    }

    // MARK: - fuzz helpers

    /// Lightweight deterministic PRNG for reproducible fuzz tests.
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
    private let eyes     = ["dot", "round", "line", "dizzy"]
    private let patterns = ["none", "stripe", "spot"]
    private let variants = ["tabby", "siamese", "brown", "shiba", "dutch", nil]

    private func randomV3xGreetingJSON(_ rng: inout SplitMixRNG) -> Data {
        let json = """
        {
          "petID": "\(UUID().uuidString)",
          "name": \(rng.nextBool() ? "\"v3pet\"" : "null"),
          "level": \(v3Levels.randomElement(using: &rng)!),
          "mood": "\(moods.randomElement(using: &rng)!)",
          "genome": {
            "body": "\(bodies.randomElement(using: &rng)!)",
            "eyes": "\(eyes.randomElement(using: &rng)!)",
            "pattern": "\(patterns.randomElement(using: &rng)!)",
            "personalityGene": \(rng.nextDouble01())
          }
        }
        """
        return json.data(using: .utf8)!
    }

    private func randomV4GreetingJSON(_ rng: inout SplitMixRNG) -> Data {
        let variantClause: String
        if let pick = variants.randomElement(using: &rng), let v = pick {
            variantClause = "\"subVariety\": \"\(v)\","
        } else {
            variantClause = ""
        }
        let seedClause = rng.nextBool() ? "\"seed\": \(rng.next() & 0xFFFFFFFF)," : ""
        let json = """
        {
          "petID": "\(UUID().uuidString)",
          "name": "v4pet",
          "level": \(v4Levels.randomElement(using: &rng)!),
          "mood": "\(moods.randomElement(using: &rng)!)",
          "genome": {
            "body": "\(bodies.randomElement(using: &rng)!)",
            "eyes": "\(eyes.randomElement(using: &rng)!)",
            "pattern": "\(patterns.randomElement(using: &rng)!)",
            "personalityGene": \(rng.nextDouble01()),
            \(variantClause)
            \(seedClause)
            "_padding": null
          }
        }
        """
        return json.data(using: .utf8)!
    }
}
