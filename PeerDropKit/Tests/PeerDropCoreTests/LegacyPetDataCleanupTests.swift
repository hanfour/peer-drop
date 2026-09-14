import XCTest
@testable import PeerDropCore

final class LegacyPetDataCleanupTests: XCTestCase {

    private final class FakeKVStore: LegacyPetKeyValueStore {
        var removed: [String] = []
        var synchronizeCount = 0
        func removeObject(forKey aKey: String) { removed.append(aKey) }
        @discardableResult func synchronize() -> Bool { synchronizeCount += 1; return true }
    }

    private var root: URL!
    private var docs: URL!
    private var group: URL!
    private var cloud: URL!
    private var defaults: UserDefaults!
    private var groupDefaults: UserDefaults!
    private var defaultsSuite: String!
    private var groupSuite: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyPetDataCleanupTests-\(UUID().uuidString)")
        docs = root.appendingPathComponent("Documents")
        group = root.appendingPathComponent("Group")
        cloud = root.appendingPathComponent("Cloud")
        for dir in [docs!, group!, cloud!] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defaultsSuite = "test.legacy-pet.\(UUID().uuidString)"
        groupSuite = "test.legacy-pet.group.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
        groupDefaults = UserDefaults(suiteName: groupSuite)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: defaultsSuite)
        groupDefaults.removePersistentDomain(forName: groupSuite)
        try? FileManager.default.removeItem(at: root)
    }

    private func seedLegacyData() throws {
        let petData = docs.appendingPathComponent("PetData")
        try FileManager.default.createDirectory(at: petData.appendingPathComponent("snapshots"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: petData.appendingPathComponent("pet.json"))
        try Data("{}".utf8).write(to: petData.appendingPathComponent("snapshots/lv1_cat.json"))
        try Data("{}".utf8).write(to: group.appendingPathComponent("pet-snapshot.json"))
        try Data([0x89, 0x50]).write(to: group.appendingPathComponent("pet-rendered.png"))
        let cloudPet = cloud.appendingPathComponent("Documents/PetData")
        try FileManager.default.createDirectory(at: cloudPet, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: cloudPet.appendingPathComponent("pet.json"))
        for key in LegacyPetDataCleanup.standardDefaultsKeys { defaults.set("x", forKey: key) }
        groupDefaults.set(Data([0xDE, 0xAD]), forKey: LegacyPetDataCleanup.appGroupDefaultsKey)
        // Unrelated data that must survive.
        try Data("keep".utf8).write(to: docs.appendingPathComponent("ChatData.keep"))
        defaults.set(true, forKey: "hasCompletedOnboarding")
    }

    private func makeCleanup(kv: FakeKVStore) -> LegacyPetDataCleanup {
        LegacyPetDataCleanup(
            documentsDirectory: docs,
            appGroupContainer: group,
            ubiquityContainer: cloud,
            defaults: defaults,
            appGroupDefaults: groupDefaults,
            kvStore: kv
        )
    }

    func testRunRemovesEveryLegacyLocationAndKeepsUnrelatedData() throws {
        try seedLegacyData()
        let kv = FakeKVStore()
        makeCleanup(kv: kv).run()

        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: docs.appendingPathComponent("PetData").path))
        XCTAssertFalse(fm.fileExists(atPath: group.appendingPathComponent("pet-snapshot.json").path))
        XCTAssertFalse(fm.fileExists(atPath: group.appendingPathComponent("pet-rendered.png").path))
        XCTAssertFalse(fm.fileExists(atPath: cloud.appendingPathComponent("Documents/PetData").path))
        for key in LegacyPetDataCleanup.standardDefaultsKeys {
            XCTAssertNil(defaults.object(forKey: key), key)
        }
        XCTAssertNil(groupDefaults.object(forKey: LegacyPetDataCleanup.appGroupDefaultsKey))
        XCTAssertEqual(Set(kv.removed), Set(LegacyPetDataCleanup.kvStoreKeys))
        XCTAssertEqual(kv.synchronizeCount, 1)

        XCTAssertTrue(fm.fileExists(atPath: docs.appendingPathComponent("ChatData.keep").path))
        XCTAssertTrue(defaults.bool(forKey: "hasCompletedOnboarding"))
    }

    func testRunIfNeededIsOneShot() throws {
        try seedLegacyData()
        let kv = FakeKVStore()
        let cleanup = makeCleanup(kv: kv)

        XCTAssertTrue(cleanup.runIfNeeded(), "first call must run")
        XCTAssertTrue(defaults.bool(forKey: LegacyPetDataCleanup.markerKey))
        XCTAssertTrue(defaults.bool(forKey: LegacyPetDataCleanup.cloudMarkerKey))

        // Re-seed a file; second call must NOT touch it.
        let petData = docs.appendingPathComponent("PetData")
        try FileManager.default.createDirectory(at: petData, withIntermediateDirectories: true)
        XCTAssertFalse(cleanup.runIfNeeded(), "second call must be a no-op")
        XCTAssertTrue(FileManager.default.fileExists(atPath: petData.path))
        XCTAssertEqual(kv.synchronizeCount, 1)
    }

    func testRunToleratesMissingOptionalContainers() throws {
        try seedLegacyData()
        let cleanup = LegacyPetDataCleanup(
            documentsDirectory: docs,
            appGroupContainer: nil,
            ubiquityContainer: nil,
            defaults: defaults,
            appGroupDefaults: nil,
            kvStore: nil
        )
        XCTAssertTrue(cleanup.runIfNeeded())
        XCTAssertFalse(FileManager.default.fileExists(atPath: docs.appendingPathComponent("PetData").path))
        // Group container untouched because none was supplied.
        XCTAssertTrue(FileManager.default.fileExists(atPath: group.appendingPathComponent("pet-snapshot.json").path))
        XCTAssertTrue(defaults.bool(forKey: LegacyPetDataCleanup.markerKey))
        XCTAssertFalse(defaults.bool(forKey: LegacyPetDataCleanup.cloudMarkerKey))
    }

    func testCloudPassRetriesUntilContainerAvailable() throws {
        try seedLegacyData()

        // First launch: not signed into iCloud / offline — no ubiquity container, no KVS.
        let offlineCleanup = LegacyPetDataCleanup(
            documentsDirectory: docs,
            appGroupContainer: group,
            ubiquityContainer: nil,
            defaults: defaults,
            appGroupDefaults: groupDefaults,
            kvStore: nil
        )
        XCTAssertTrue(offlineCleanup.runIfNeeded(), "local pass should still run")
        XCTAssertTrue(defaults.bool(forKey: LegacyPetDataCleanup.markerKey))
        XCTAssertFalse(defaults.bool(forKey: LegacyPetDataCleanup.cloudMarkerKey))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: cloud.appendingPathComponent("Documents/PetData").path),
            "cloud data must be untouched while the container is unreachable"
        )

        // Later launch: the user signed into iCloud / came back online.
        let kv = FakeKVStore()
        let onlineCleanup = LegacyPetDataCleanup(
            documentsDirectory: docs,
            appGroupContainer: group,
            ubiquityContainer: cloud,
            defaults: defaults,
            appGroupDefaults: groupDefaults,
            kvStore: kv
        )
        XCTAssertTrue(onlineCleanup.runIfNeeded(), "cloud pass should run now that the container is available")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloud.appendingPathComponent("Documents/PetData").path))
        XCTAssertEqual(Set(kv.removed), Set(LegacyPetDataCleanup.kvStoreKeys))
        XCTAssertTrue(defaults.bool(forKey: LegacyPetDataCleanup.cloudMarkerKey))

        XCTAssertFalse(onlineCleanup.runIfNeeded(), "third call is a full no-op")
    }
}
