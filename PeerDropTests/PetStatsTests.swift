import XCTest
@testable import PeerDrop

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
        XCTAssertEqual(PetLevel.egg.displayName, "蛋")
        XCTAssertEqual(PetLevel.baby.displayName, "幼年")
        XCTAssertEqual(PetLevel.child.displayName, "成長")
    }
}
