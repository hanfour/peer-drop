import XCTest
@testable import PeerDrop

final class V4UpgradeOnboardingTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // Per-test ephemeral defaults suite so flag changes don't leak.
        // The fresh UUID-suffixed suite name is itself the isolation
        // mechanism — no extra cleanup needed.
        defaults = UserDefaults(suiteName: "V4UpgradeOnboardingTests-\(UUID())")
    }

    override func tearDown() {
        defaults.removeObject(forKey: "v4UpgradeShown")
        defaults = nil
        super.tearDown()
    }

    // MARK: - shouldPresent gate

    func test_shouldPresent_trueWhenMigratedAndFlagFalse() {
        var pet = PetState.newEgg()
        pet.migrationDoneAt = Date()              // v3.x → v4.0 migration ran

        XCTAssertTrue(V4UpgradeOnboarding.shouldPresent(for: pet, defaults: defaults))
    }

    func test_shouldPresent_falseWhenFlagTrue() {
        var pet = PetState.newEgg()
        pet.migrationDoneAt = Date()
        defaults.set(true, forKey: "v4UpgradeShown")

        XCTAssertFalse(V4UpgradeOnboarding.shouldPresent(for: pet, defaults: defaults))
    }

    func test_shouldPresent_falseForFreshV4Install() {
        // newEgg() leaves migrationDoneAt nil — this is the brand-new v4.0
        // user who never had a v3.x pet to upgrade. Onboarding shouldn't
        // show "your pet got a glow-up" if the pet didn't exist before.
        let pet = PetState.newEgg()
        XCTAssertNil(pet.migrationDoneAt, "test setup sanity")

        XCTAssertFalse(V4UpgradeOnboarding.shouldPresent(for: pet, defaults: defaults))
    }

    func test_shouldPresent_falseEvenWhenFlagFalse_ifNotMigrated() {
        // Defensive: a corrupt state (flag never set + no migration) should
        // still suppress the screen.
        let pet = PetState.newEgg()
        defaults.set(false, forKey: "v4UpgradeShown")

        XCTAssertFalse(V4UpgradeOnboarding.shouldPresent(for: pet, defaults: defaults))
    }
}
