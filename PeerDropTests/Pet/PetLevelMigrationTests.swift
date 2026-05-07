import XCTest
@testable import PeerDrop

private struct LevelHolder: Codable, Equatable {
    let level: PetLevel
}

final class PetLevelMigrationTests: XCTestCase {
    // MARK: rawValue contract (network/persistence compat)

    func test_baby_rawValue_is2() { XCTAssertEqual(PetLevel.baby.rawValue, 2) }
    func test_adult_rawValue_is3_sameAsLegacyChild() { XCTAssertEqual(PetLevel.adult.rawValue, 3) }
    func test_elder_rawValue_is4() { XCTAssertEqual(PetLevel.elder.rawValue, 4) }

    // MARK: Codable round-trip

    func test_decode_legacyRawValue3_becomesAdult() throws {
        let json = #"{"level":3}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(LevelHolder.self, from: json)
        XCTAssertEqual(decoded.level, .adult)
    }

    func test_decode_newRawValue4_becomesElder() throws {
        let json = #"{"level":4}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(LevelHolder.self, from: json)
        XCTAssertEqual(decoded.level, .elder)
    }

    func test_encode_adult_writesInt3() throws {
        let data = try JSONEncoder().encode(LevelHolder(level: .adult))
        XCTAssertEqual(String(data: data, encoding: .utf8), #"{"level":3}"#)
    }

    func test_encode_elder_writesInt4() throws {
        let data = try JSONEncoder().encode(LevelHolder(level: .elder))
        XCTAssertEqual(String(data: data, encoding: .utf8), #"{"level":4}"#)
    }

    // MARK: CaseIterable (must include elder)

    func test_allCases_containsElder() {
        XCTAssertTrue(PetLevel.allCases.contains(.elder))
        XCTAssertEqual(PetLevel.allCases.count, 3)
    }

    func test_decoder_maps_legacy_egg_rawValue_to_baby() throws {
        // v3.x persisted PetLevel as rawValue 1 (.egg). v4.0.1 decoder
        // must map it to .baby silently.
        let json = "1".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PetLevel.self, from: json)
        XCTAssertEqual(decoded, .baby, "rawValue 1 must decode to .baby (was .egg in v3)")
    }

    func test_decoder_unknown_rawValue_falls_back_to_baby() throws {
        let json = "99".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PetLevel.self, from: json)
        XCTAssertEqual(decoded, .baby, "unknown raw values fall back to .baby (forward compat)")
    }

    func test_decoder_preserves_baby_adult_elder() throws {
        for (raw, expected) in [(2, PetLevel.baby), (3, .adult), (4, .elder)] {
            let decoded = try JSONDecoder().decode(PetLevel.self, from: "\(raw)".data(using: .utf8)!)
            XCTAssertEqual(decoded, expected)
        }
    }

    func test_legacyEgg_decode_then_encode_writesBaby_rawValue2() throws {
        // Migration semantics: read v3 rawValue 1, write back as rawValue 2.
        // Locks in the "no .egg case" decision against accidental re-introduction.
        let decoded = try JSONDecoder().decode(PetLevel.self, from: "1".data(using: .utf8)!)
        let reencoded = try JSONEncoder().encode(decoded)
        XCTAssertEqual(String(data: reencoded, encoding: .utf8), "2",
                       "v3 egg decoded as .baby must persist back as rawValue 2 (write-once migration)")
    }
}
