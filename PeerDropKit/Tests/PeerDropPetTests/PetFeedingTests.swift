import XCTest
import PeerDropPet
@testable import PeerDropPet

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

    // Audit round 20: dropFood now reports WHY it no-ops so the tap-to-feed
    // UI can give the user feedback instead of silently doing nothing.

    func testDropFoodReturnsFedOnSuccess() {
        var pet = PetState.newEgg()
        pet.level = .baby
        let engine = PetEngine(pet: pet)
        XCTAssertEqual(engine.dropFood(.rice, at: CGPoint(x: 200, y: 600)), .fed)
    }

    func testDropFoodReturnsOutOfStockWhenEmpty() {
        var pet = PetState.newEgg()
        pet.level = .baby
        pet.foodInventory.items = []
        let engine = PetEngine(pet: pet)
        XCTAssertEqual(engine.dropFood(.rice, at: CGPoint(x: 200, y: 600)), .outOfStock)
    }

    func testDropFoodReturnsOnCooldown() {
        var pet = PetState.newEgg()
        pet.level = .baby
        pet.lastFedAt = Date()
        let engine = PetEngine(pet: pet)
        XCTAssertEqual(engine.dropFood(.rice, at: CGPoint(x: 200, y: 600)), .onCooldown)
    }
}
