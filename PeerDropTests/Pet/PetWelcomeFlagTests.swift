import XCTest
@testable import PeerDrop

final class PetWelcomeFlagTests: XCTestCase {
    private let testKey = "test_hasSeenPetWelcome_v4"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: testKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: testKey)
        super.tearDown()
    }

    func test_first_launch_shouldShow_is_true() {
        let flag = PetWelcomeFlag(key: testKey)
        XCTAssertTrue(flag.shouldShow)
    }

    func test_after_markSeen_shouldShow_is_false() {
        let flag = PetWelcomeFlag(key: testKey)
        flag.markSeen()
        XCTAssertFalse(flag.shouldShow)
    }

    func test_persists_across_instances() {
        let flag1 = PetWelcomeFlag(key: testKey)
        flag1.markSeen()
        let flag2 = PetWelcomeFlag(key: testKey)
        XCTAssertFalse(flag2.shouldShow)
    }
}
