import XCTest
@testable import PeerDrop

@MainActor
final class V5UpgradeOnboardingTests: XCTestCase {

    private var defaults: UserDefaults!

    /// Reference release date for tests — birthDate values straddle this.
    private let testReleaseDate: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 9; c.day = 1
        c.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: c)!
    }()

    /// A pet whose birthDate is BEFORE the release date — a v4-era user.
    private func preV5Pet() -> PetState {
        var pet = PetState.newEgg()
        pet.birthDate = testReleaseDate.addingTimeInterval(-86400 * 30)  // 30 days before
        return pet
    }

    /// A pet whose birthDate is AFTER the release date — created on v5 fresh install.
    private func postV5Pet() -> PetState {
        var pet = PetState.newEgg()
        pet.birthDate = testReleaseDate.addingTimeInterval(86400 * 30)  // 30 days after
        return pet
    }

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

    func test_shouldPresent_noPetAndNoFlags_returnsFalse() {
        // Fresh v5 install, never had a pet, never went through v4 upgrade.
        XCTAssertFalse(V5UpgradeOnboarding.shouldPresent(
            pet: nil, defaults: defaults, v5ReleaseDate: testReleaseDate))
    }

    func test_shouldPresent_v4MigratorFlagAlone_returnsTrue() {
        // User went through v3.x→v4 upgrade. Strongest signal — fires
        // regardless of whether they have a pet right now.
        defaults.set(true, forKey: "v4UpgradeShown")
        XCTAssertTrue(V5UpgradeOnboarding.shouldPresent(
            pet: nil, defaults: defaults, v5ReleaseDate: testReleaseDate))
    }

    func test_shouldPresent_petWithPreV5BirthDate_returnsTrue() {
        // No v4 upgrade flag, but pet was created before v5 shipped — they
        // had v4 animations and now see v5 animations. Show the upgrade.
        XCTAssertTrue(V5UpgradeOnboarding.shouldPresent(
            pet: preV5Pet(), defaults: defaults, v5ReleaseDate: testReleaseDate))
    }

    func test_shouldPresent_petWithPostV5BirthDate_returnsFalse() {
        // Pet was created on v5 — user never had v4 animations to compare.
        // This is the regression scenario flagged in PR #30 review (S2):
        // pre-fix, hasCompletedOnboarding=true would have made this true.
        defaults.set(true, forKey: "hasCompletedOnboarding")  // intentionally still set
        XCTAssertFalse(V5UpgradeOnboarding.shouldPresent(
            pet: postV5Pet(), defaults: defaults, v5ReleaseDate: testReleaseDate))
    }

    func test_shouldPresent_alreadyShown_returnsFalseEvenWithStrongSignals() {
        // Once dismissed, never again — even for users with both v4Upgrade
        // and pre-v5 pet flags.
        defaults.set(true, forKey: "v4UpgradeShown")
        defaults.set(true, forKey: "v5UpgradeShown")
        XCTAssertFalse(V5UpgradeOnboarding.shouldPresent(
            pet: preV5Pet(), defaults: defaults, v5ReleaseDate: testReleaseDate))
    }

    func test_shouldPresent_petAtExactReleaseDate_returnsFalse() {
        // Boundary: pets with birthDate >= release date are treated as
        // post-v5. < (strict) is the qualifying condition.
        var pet = PetState.newEgg()
        pet.birthDate = testReleaseDate
        XCTAssertFalse(V5UpgradeOnboarding.shouldPresent(
            pet: pet, defaults: defaults, v5ReleaseDate: testReleaseDate))
    }
}
