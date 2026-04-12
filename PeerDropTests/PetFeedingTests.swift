import XCTest
@testable import PeerDrop

@MainActor
final class PetFeedingTests: XCTestCase {
    func testDropFoodSetsTarget() {
        var pet = PetState.newEgg()
        pet.level = .baby
        let engine = PetEngine(pet: pet)
        engine.dropFood(.rice, at: CGPoint(x: 200, y: 600))
        XCTAssertNotNil(engine.foodTarget)
        XCTAssertEqual(engine.foodTarget?.type, .rice)
    }

    func testDropFoodFailsWhenEmpty() {
        var pet = PetState.newEgg()
        pet.level = .baby
        pet.foodInventory.items = []
        let engine = PetEngine(pet: pet)
        engine.dropFood(.rice, at: CGPoint(x: 200, y: 600))
        XCTAssertNil(engine.foodTarget)
    }

    func testConsumeFoodAwardsXP() {
        var pet = PetState.newEgg()
        pet.level = .baby
        let engine = PetEngine(pet: pet)
        let xpBefore = engine.pet.experience
        engine.dropFood(.rice, at: CGPoint(x: 200, y: 600))
        engine.consumeFood()
        XCTAssertEqual(engine.pet.experience, xpBefore + 3)
        XCTAssertNil(engine.foodTarget)
        XCTAssertEqual(engine.pet.lifeState, .digesting)
    }

    func testFishSetsMoodHappy() {
        var pet = PetState.newEgg()
        pet.level = .baby
        pet.foodInventory.items = [FoodItem(type: .fish, count: 1)]
        let engine = PetEngine(pet: pet)
        engine.dropFood(.fish, at: CGPoint(x: 200, y: 600))
        engine.consumeFood()
        XCTAssertEqual(engine.pet.mood, .happy)
    }

    func testCooldownPreventsFeeding() {
        var pet = PetState.newEgg()
        pet.level = .baby
        pet.lastFedAt = Date()
        let engine = PetEngine(pet: pet)
        engine.dropFood(.rice, at: CGPoint(x: 200, y: 600))
        XCTAssertNil(engine.foodTarget)
    }
}
