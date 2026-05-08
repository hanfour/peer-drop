import XCTest
@testable import PeerDrop

@MainActor
final class V5UpgradeOnboardingTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // Per-test UserDefaults suite to avoid cross-test bleed and to keep
        // away from the device's standard suite during CI.
        defaults = UserDefaults(suiteName: "v5-upgrade-tests-\(UUID().uuidString)")!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaults.dictionaryRepresentation()["__suiteName__"] as? String ?? "")
        defaults = nil
        super.tearDown()
    }

    // MARK: - shouldPresent gate

    func test_shouldPresent_freshInstall_returnsFalse() {
        // No flags set — fresh v5 install. Don't show.
        XCTAssertFalse(V5UpgradeOnboarding.shouldPresent(defaults: defaults))
    }

    func test_shouldPresent_v4Migrator_returnsTrue() {
        // User went through v4 upgrade; now on v5 first launch.
        defaults.set(true, forKey: "v4UpgradeShown")
        XCTAssertTrue(V5UpgradeOnboarding.shouldPresent(defaults: defaults))
    }

    func test_shouldPresent_completedOnboarding_returnsTrue() {
        // User finished initial onboarding on v4 (no v3.x history); v5 first launch.
        defaults.set(true, forKey: "hasCompletedOnboarding")
        XCTAssertTrue(V5UpgradeOnboarding.shouldPresent(defaults: defaults))
    }

    func test_shouldPresent_alreadyShown_returnsFalse() {
        // Once dismissed, never again.
        defaults.set(true, forKey: "v4UpgradeShown")
        defaults.set(true, forKey: "v5UpgradeShown")
        XCTAssertFalse(V5UpgradeOnboarding.shouldPresent(defaults: defaults))
    }

    func test_shouldPresent_alreadyShown_evenWithOnboardingComplete_returnsFalse() {
        defaults.set(true, forKey: "hasCompletedOnboarding")
        defaults.set(true, forKey: "v5UpgradeShown")
        XCTAssertFalse(V5UpgradeOnboarding.shouldPresent(defaults: defaults))
    }
}
