import XCTest
@testable import PeerDrop

final class FoodInventoryTests: XCTestCase {

    func testFoodTypeProperties() {
        XCTAssertEqual(FoodType.rice.emoji, "🍚")
        XCTAssertEqual(FoodType.rice.xp, 3)
        XCTAssertEqual(FoodType.fish.xp, 5)
        XCTAssertEqual(FoodType.apple.xp, 4)
    }

    func testFoodTypeDigestRange() {
        XCTAssertEqual(FoodType.rice.digestMinSeconds, 1800)
        XCTAssertEqual(FoodType.rice.digestMaxSeconds, 7200)
        XCTAssertEqual(FoodType.apple.digestMinSeconds, 900)
        XCTAssertEqual(FoodType.apple.digestMaxSeconds, 3600)
    }

    func testInventoryConsumeDecrementsCount() {
        var inv = FoodInventory()
        inv.items = [FoodItem(type: .rice, count: 3)]
        XCTAssertTrue(inv.consume(.rice))
        XCTAssertEqual(inv.count(of: .rice), 2)
    }

    func testInventoryConsumeEmptyReturnsFalse() {
        var inv = FoodInventory()
        inv.items = []
        XCTAssertFalse(inv.consume(.rice))
    }

    func testInventoryConsumeRemovesZeroCountItem() {
        var inv = FoodInventory()
        inv.items = [FoodItem(type: .rice, count: 1)]
        _ = inv.consume(.rice)
        XCTAssertEqual(inv.count(of: .rice), 0)
    }

    func testInventoryAdd() {
        var inv = FoodInventory()
        inv.items = [FoodItem(type: .rice, count: 2)]
        inv.add(.rice, count: 3)
        XCTAssertEqual(inv.count(of: .rice), 5)
    }

    func testInventoryAddNewType() {
        var inv = FoodInventory()
        inv.items = []
        inv.add(.fish, count: 1)
        XCTAssertEqual(inv.count(of: .fish), 1)
    }

    func testDailyRefresh() {
        var inv = FoodInventory()
        inv.items = []
        inv.applyDailyRefresh()
        XCTAssertEqual(inv.count(of: .rice), 3)
        XCTAssertEqual(inv.count(of: .apple), 1)
    }

    func testFishMoodEffect() {
        XCTAssertEqual(FoodType.fish.moodEffect, .happy)
        XCTAssertNil(FoodType.rice.moodEffect)
    }
}
