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

    // MARK: - PetTabView.shouldPresentWelcome (final-review I-1)

    /// Helper: fresh-install pet has migrationDoneAt == nil (newEgg() default).
    private func makeFreshInstallPet() -> PetState {
        PetState(
            id: UUID(),
            name: nil,
            birthDate: Date(),
            level: .baby,
            experience: 0,
            genome: .random(),
            mood: .curious,
            socialLog: [],
            lastInteraction: Date()
        )
    }

    /// Helper: v3.x migrator has migrationDoneAt set by applyV4Migration.
    private func makeMigratorPet() -> PetState {
        var pet = makeFreshInstallPet()
        pet.migrationDoneAt = Date()
        return pet
    }

    func test_shouldPresentWelcome_freshInstall_andFlagSet_returnsTrue() {
        let flag = PetWelcomeFlag(key: testKey)  // shouldShow == true
        let pet = makeFreshInstallPet()           // migrationDoneAt == nil
        XCTAssertTrue(PetTabView.shouldPresentWelcome(flag: flag, pet: pet))
    }

    func test_shouldPresentWelcome_migrator_isSuppressed_evenWhenFlagSet() {
        let flag = PetWelcomeFlag(key: testKey)  // shouldShow == true
        let pet = makeMigratorPet()              // migrationDoneAt != nil
        XCTAssertFalse(
            PetTabView.shouldPresentWelcome(flag: flag, pet: pet),
            "v3.x migrators (egg or past-egg) must not see PetWelcomeView — V4UpgradeOnboarding is the correct reveal for them."
        )
    }

    func test_shouldPresentWelcome_freshInstall_butFlagAlreadySeen_returnsFalse() {
        let flag = PetWelcomeFlag(key: testKey)
        flag.markSeen()                          // shouldShow == false
        let pet = makeFreshInstallPet()
        XCTAssertFalse(PetTabView.shouldPresentWelcome(flag: flag, pet: pet))
    }
}
