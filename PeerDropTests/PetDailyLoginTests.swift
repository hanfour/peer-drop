import XCTest
@testable import PeerDrop

@MainActor
final class PetDailyLoginTests: XCTestCase {
    func testDailyRefreshAddsFood() {
        var pet = PetState.newEgg()
        pet.level = .baby
        pet.foodInventory.items = []
        pet.lastLoginDate = Calendar.current.date(byAdding: .day, value: -1, to: Date())
        let engine = PetEngine(pet: pet)
        engine.checkDailyLogin()
        XCTAssertEqual(engine.pet.foodInventory.count(of: .rice), 3)
        XCTAssertEqual(engine.pet.foodInventory.count(of: .apple), 1)
    }

    func testSameDayDoesNotRefresh() {
        var pet = PetState.newEgg()
        pet.level = .baby
        pet.foodInventory.items = []
        pet.lastLoginDate = Date()
        let engine = PetEngine(pet: pet)
        engine.checkDailyLogin()
        XCTAssertEqual(engine.pet.foodInventory.count(of: .rice), 0)
    }

    func testPeerConnectionAwardsRandomFood() {
        var pet = PetState.newEgg()
        pet.level = .baby
        pet.foodInventory.items = []
        let engine = PetEngine(pet: pet)
        engine.onPeerConnected()
        let total = FoodType.allCases.reduce(0) { $0 + engine.pet.foodInventory.count(of: $1) }
        XCTAssertEqual(total, 1)
    }

    func testInteractionIncrementsStat() {
        var pet = PetState.newEgg()
        pet.level = .baby
        let engine = PetEngine(pet: pet)
        let before = engine.pet.stats.totalInteractions
        engine.handleInteraction(.tap)
        XCTAssertEqual(engine.pet.stats.totalInteractions, before + 1)
    }
}
