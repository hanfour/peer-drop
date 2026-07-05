import XCTest
import PeerDropPet
@testable import PeerDropPet

final class PetStatsTests: XCTestCase {

    func testDefaultStatsAreZero() {
        let stats = PetStats()
        XCTAssertEqual(stats.totalInteractions, 0)
        XCTAssertEqual(stats.poopsCleaned, 0)
        XCTAssertEqual(stats.petsMet, 0)
        XCTAssertEqual(stats.foodsEaten, 0)
    }

    func testPetStateHasFoodInventory() {
        var pet = PetState.newEgg()
        XCTAssertEqual(pet.foodInventory.count(of: .rice), 3)
        XCTAssertTrue(pet.foodInventory.consume(.rice))
    }

    func testPetStateHasStats() {
        var pet = PetState.newEgg()
        pet.stats.totalInteractions += 1
        XCTAssertEqual(pet.stats.totalInteractions, 1)
    }

    func testPetAgeInDays() {
        var pet = PetState.newEgg()
        pet.birthDate = Date().addingTimeInterval(-86400 * 5)
        XCTAssertEqual(pet.ageInDays, 5)
    }

    func testPetLifeStateDefault() {
        let pet = PetState.newEgg()
        XCTAssertEqual(pet.lifeState, .idle)
    }

    func testPetLevelDisplayName() {
        // displayName is now localized via Bundle.module, so the exact string
        // depends on the test host's language. Assert (locale-independently)
        // that each stage resolves to one of its shipped translations and never
        // leaks the raw catalog key. Exact per-language values are pinned in
        // EnumLocalizationTests.
        let known: [PetLevel: Set<String>] = [
            .baby:  ["Baby", "幼年", "ベビー", "아기"],
            .adult: ["Adult", "成熟", "おとな", "성체"],
            .elder: ["Elder", "老年", "シニア", "노년"],
        ]
        for level in PetLevel.allCases {
            let name = level.displayName
            XCTAssertFalse(name.hasPrefix("pet."), "\(level).displayName leaked raw key: \(name)")
            XCTAssertTrue(known[level]!.contains(name), "\(level).displayName unexpected: \(name)")
        }
    }
}
