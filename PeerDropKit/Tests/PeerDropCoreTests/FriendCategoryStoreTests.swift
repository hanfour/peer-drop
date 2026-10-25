import XCTest
import CryptoKit
import PeerDropSecurity
@testable import PeerDropCore

@MainActor
final class FriendCategoryStoreTests: XCTestCase {
    private var dir: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private let encryptor = ChatDataEncryptor(testKey: SymmetricKey(size: .bits256))

    override func setUp() async throws {
        try await super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("fcs-\(UUID().uuidString)")
        suite = "fcs-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        defaults.removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    private func makeStore(legacy: [DeviceGroup] = []) -> FriendCategoryStore {
        FriendCategoryStore(directory: dir, encryptor: encryptor, legacyGroups: legacy, migrationDefaults: defaults)
    }

    func testCreateTrimsAndRejectsBlankAndOverlong() {
        let s = makeStore()
        XCTAssertEqual(s.create(name: "  家人  ")?.name, "家人")
        XCTAssertNil(s.create(name: "   "))
        XCTAssertNil(s.create(name: ""))
        XCTAssertNil(s.create(name: String(repeating: "a", count: 21)))
        XCTAssertNotNil(s.create(name: String(repeating: "a", count: 20)))
        XCTAssertEqual(s.categories.count, 2)
    }

    func testCreateRejectsAfter20() {
        let s = makeStore()
        for i in 0..<20 { XCTAssertNotNil(s.create(name: "c\(i)")) }
        XCTAssertNil(s.create(name: "extra"))
        XCTAssertEqual(s.categories.count, 20)
    }

    func testSetPresenceRejectsInvalidScheduleAndPersists() {
        let s = makeStore()
        let c = s.create(name: "A")!
        let bad = ScheduleWindow(weekdays: [], startMinute: 600, endMinute: 600)
        XCTAssertFalse(s.setPresence(.scheduled(bad), for: c.id))
        XCTAssertEqual(s.categories[0].presence, .online)
        XCTAssertFalse(s.setPresence(.offline, for: "missing"))
        let good = ScheduleWindow(weekdays: [6], startMinute: 1320, endMinute: 420)
        XCTAssertTrue(s.setPresence(.scheduled(good), for: c.id))
        XCTAssertEqual(makeStore().categories[0].presence, .scheduled(good))
    }

    func testSetStatusMessageTrimsRejectsOverlongAndClears() {
        let s = makeStore()
        let c = s.create(name: "A")!
        XCTAssertTrue(s.setStatusMessage("  hello\nworld ", for: c.id))
        XCTAssertEqual(s.categories[0].statusMessage, "hello world")
        XCTAssertFalse(s.setStatusMessage(String(repeating: "😀", count: 61), for: c.id))
        XCTAssertEqual(s.categories[0].statusMessage, "hello world")
        XCTAssertTrue(s.setStatusMessage(String(repeating: "😀", count: 60), for: c.id))
        XCTAssertTrue(s.setStatusMessage("  ", for: c.id))
        XCTAssertNil(s.categories[0].statusMessage)
        XCTAssertNil(makeStore().categories[0].statusMessage)
    }

    func testSetShowStatusMessagePersists() {
        let s = makeStore()
        let c = s.create(name: "A")!
        s.setShowStatusMessage(false, for: c.id)
        XCTAssertFalse(s.categories[0].showStatusMessage)
        XCTAssertFalse(makeStore().categories[0].showStatusMessage)
    }

    func testAssignKeepsOneCategoryPerFriend() {
        let s = makeStore()
        let a = s.create(name: "A")!, b = s.create(name: "B")!
        s.assign(friendID: "f1", to: a.id)
        s.assign(friendID: "f1", to: b.id)
        XCTAssertEqual(s.categories.first { $0.id == a.id }?.friendIDs, [])
        XCTAssertEqual(s.categories.first { $0.id == b.id }?.friendIDs, ["f1"])
    }

    func testAssignNilUncategorizes() {
        let s = makeStore()
        let a = s.create(name: "A")!
        s.assign(friendID: "f1", to: a.id)
        s.assign(friendID: "f1", to: nil)
        XCTAssertEqual(s.categories.first?.friendIDs, [])
        XCTAssertNil(s.category(containingAnyOf: ["f1"]))
    }

    func testDeleteReturnsMembersToUncategorized() {
        let s = makeStore()
        let a = s.create(name: "A")!
        s.assign(friendID: "f1", to: a.id)
        s.delete(id: a.id)
        XCTAssertTrue(s.categories.isEmpty)
        XCTAssertNil(s.category(containingAnyOf: ["f1"]))
    }

    func testCategoryContainingAnyOfMatchesEitherRecordOfSamePerson() {
        let s = makeStore()
        let a = s.create(name: "A")!
        s.assign(friendID: "rec1", to: a.id)
        XCTAssertEqual(s.category(containingAnyOf: ["rec2", "rec1"])?.id, a.id)
        XCTAssertNil(s.category(containingAnyOf: ["rec2"]))
    }

    func testNotificationsDefaultTrueWhenUncategorized() {
        let s = makeStore()
        XCTAssertTrue(s.notificationsEnabled(forAnyOf: ["nobody"]))
        let a = s.create(name: "A")!
        s.assign(friendID: "f1", to: a.id)
        s.setNotificationsEnabled(false, for: a.id)
        XCTAssertFalse(s.notificationsEnabled(forAnyOf: ["x", "f1"]))
    }

    func testPersistenceRoundTripIsEncryptedOnDisk() throws {
        let s = makeStore()
        let a = s.create(name: "秘密分類")!
        s.assign(friendID: "f1", to: a.id)
        let file = dir.appendingPathComponent("categories.enc")
        let raw = try Data(contentsOf: file)
        XCTAssertNil(raw.range(of: Data("秘密分類".utf8)))
        let s2 = makeStore()
        XCTAssertEqual(s2.categories, s.categories)
        XCTAssertEqual(s2.categories.first?.friendIDs, ["f1"])
    }

    func testDecodesFileMissingF2Fields() throws {
        let json = #"[{"id":"x","name":"Old","order":0,"friendIDs":["f"],"notificationsEnabled":false}]"#
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encryptor.encryptAndWrite(Data(json.utf8), to: dir.appendingPathComponent("categories.enc"))
        let s = makeStore()
        XCTAssertEqual(s.categories.count, 1)
        XCTAssertEqual(s.categories[0].presence, .online)
        XCTAssertNil(s.categories[0].statusMessage)
        XCTAssertTrue(s.categories[0].showStatusMessage)
        XCTAssertFalse(s.categories[0].notificationsEnabled)
    }

    func testCorruptFileYieldsEmptyAndIsKept() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: dir.appendingPathComponent("categories.enc"))
        let s = makeStore()
        XCTAssertTrue(s.categories.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("categories.enc.corrupt").path))
    }

    func testMigrateDeterministicForFriendInTwoGroups() {
        let g1 = DeviceGroup(id: "g1", name: "Zeta", deviceIDs: ["f", "a"])
        let g2 = DeviceGroup(id: "g2", name: "Alpha", deviceIDs: ["f", "b"])
        let out = FriendCategoryStore.migrate(legacy: [g1, g2])
        XCTAssertEqual(out.map(\.id), ["g1", "g2"])
        XCTAssertEqual(out.map(\.order), [0, 1])
        XCTAssertEqual(out[0].friendIDs, ["a"])
        XCTAssertEqual(out[1].friendIDs, ["f", "b"])
        XCTAssertEqual(FriendCategoryStore.migrate(legacy: [g2, g1]).first { $0.id == "g2" }?.friendIDs, ["f", "b"])
    }

    func testMigrateIsIdempotent() {
        let g = DeviceGroup(id: "g1", name: "Fam", deviceIDs: ["f"])
        let s1 = makeStore(legacy: [g])
        XCTAssertEqual(s1.categories.first?.name, "Fam")
        XCTAssertTrue(defaults.bool(forKey: "peerDropCategoriesMigrated"))
        let renamed = s1.categories[0].id
        XCTAssertTrue(s1.rename(id: renamed, to: "Renamed"))
        let s2 = makeStore(legacy: [g])
        XCTAssertEqual(s2.categories.map(\.name), ["Renamed"])
        // Flag set + file gone: still no re-migration.
        try? FileManager.default.removeItem(at: dir)
        XCTAssertTrue(makeStore(legacy: [g]).categories.isEmpty)
    }

    func testMigrateKeepsEmptyGroups() {
        let out = FriendCategoryStore.migrate(legacy: [DeviceGroup(id: "e", name: "Empty")])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].friendIDs, [])
    }

    func testMigrateNameEdgeCases() {
        let out = FriendCategoryStore.migrate(legacy: [
            DeviceGroup(id: "1", name: "   "),
            DeviceGroup(id: "2", name: String(repeating: "x", count: 30)),
            DeviceGroup(id: "3", name: "  Pad  "),
        ])
        XCTAssertEqual(out[0].name, "分類")
        XCTAssertEqual(out[1].name, String(repeating: "x", count: 20))
        XCTAssertEqual(out[2].name, "Pad")
    }

    func testMoveFollowsOnMoveSemanticsAndPersistsOrder() {
        let s = makeStore()
        let a = s.create(name: "A")!, b = s.create(name: "B")!, c = s.create(name: "C")!
        s.move(order: 0, to: 3)          // A to the end
        XCTAssertEqual(s.categories.map(\.name), ["B", "C", "A"])
        s.move(order: 2, to: 0)          // A back to the front
        XCTAssertEqual(s.categories.map(\.name), ["A", "B", "C"])
        XCTAssertEqual(s.categories.map(\.order), [0, 1, 2])
        XCTAssertEqual(makeStore().categories.map(\.id), [a.id, b.id, c.id])
    }

    func testReorderPutsListedIdsFirstAndKeepsTheRest() {
        let s = makeStore()
        let a = s.create(name: "A")!, b = s.create(name: "B")!, c = s.create(name: "C")!
        s.reorder(ids: [c.id, a.id])
        XCTAssertEqual(s.categories.map(\.name), ["C", "A", "B"])
        XCTAssertEqual(s.categories.map(\.order), [0, 1, 2])
        _ = b
    }
}
