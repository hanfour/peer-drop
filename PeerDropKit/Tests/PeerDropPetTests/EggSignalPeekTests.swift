import XCTest
@testable import PeerDropPet

/// The v3.x "egg hatched" onboarding flag must be set on BOTH restore
/// paths — local disk (PetStore.loadAndMigrate) and iCloud
/// (PetCloudSync.loadAndMigrateFromCloud). The cloud path used to skip the
/// peek, so a user whose pet came down from iCloud missed the
/// "your egg has hatched" screen. This pins the shared peek helper.
final class EggSignalPeekTests: XCTestCase {

    private func defaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "egg-peek-\(UUID().uuidString)")!
        d.removePersistentDomain(forName: d.description) // ensure clean
        return d
    }

    func test_setsFlagWhenRawLevelIsOne() {
        let d = defaults()
        let json = Data(#"{"id":"p1","level":1,"experience":0}"#.utf8)
        PetStore.peekV3EggSignal(in: json, defaults: d)
        XCTAssertTrue(d.bool(forKey: "v4MigratedFromEgg"))
    }

    func test_doesNotSetFlagForNonEggLevel() {
        let d = defaults()
        let json = Data(#"{"id":"p1","level":3,"experience":500}"#.utf8)
        PetStore.peekV3EggSignal(in: json, defaults: d)
        XCTAssertFalse(d.bool(forKey: "v4MigratedFromEgg"))
    }

    func test_isIdempotentAndSurvivesGarbage() {
        let d = defaults()
        PetStore.peekV3EggSignal(in: Data("not json".utf8), defaults: d) // must not crash
        XCTAssertFalse(d.bool(forKey: "v4MigratedFromEgg"))
        let egg = Data(#"{"level":1}"#.utf8)
        PetStore.peekV3EggSignal(in: egg, defaults: d)
        PetStore.peekV3EggSignal(in: egg, defaults: d) // idempotent
        XCTAssertTrue(d.bool(forKey: "v4MigratedFromEgg"))
    }
}
