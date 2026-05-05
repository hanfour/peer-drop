import XCTest
@testable import PeerDrop

private struct LevelHolder: Codable, Equatable {
    let level: PetLevel
}

final class PetLevelMigrationTests: XCTestCase {
    // MARK: rawValue contract (network/persistence compat)

    func test_egg_rawValue_is1() { XCTAssertEqual(PetLevel.egg.rawValue, 1) }
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

    // MARK: ordering (Comparable)

    func test_ordering_eggLessThanBabyLessThanAdultLessThanElder() {
        XCTAssertLessThan(PetLevel.egg, PetLevel.baby)
        XCTAssertLessThan(PetLevel.baby, PetLevel.adult)
        XCTAssertLessThan(PetLevel.adult, PetLevel.elder)
    }

    // MARK: CaseIterable (must include elder)

    func test_allCases_containsElder() {
        XCTAssertTrue(PetLevel.allCases.contains(.elder))
        XCTAssertEqual(PetLevel.allCases.count, 4)
    }
}
