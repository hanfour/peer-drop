// PeerDropKit/Tests/PeerDropCoreTests/DeviceRecordStatusTests.swift
//
// Project F2 Task 4: a friend's received category status message stored on
// `DeviceRecord` (`statusMessage`, `statusUpdatedAt`).
import XCTest
@testable import PeerDropCore
@testable import PeerDropSecurity

@MainActor
final class DeviceRecordStatusTests: XCTestCase {

    func testOldRecordJSONWithoutStatusDecodes() throws {
        // Pre-F1 shape: no peerIdentityId, no status fields.
        let json = """
        [{"id":"dev-1","displayName":"Ann","sourceType":"bonjour","lastConnected":700000000,
          "connectionCount":3,"connectionHistory":[700000000],"peerDeviceId":"uuid-1"}]
        """
        let records = try JSONDecoder().decode([DeviceRecord].self, from: Data(json.utf8))
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].id, "dev-1")
        XCTAssertEqual(records[0].connectionCount, 3)
        XCTAssertNil(records[0].statusMessage)
        XCTAssertNil(records[0].statusUpdatedAt)
    }

    func testStatusRoundTrip() throws {
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        let record = DeviceRecord(id: "dev-2", displayName: "Bo", sourceType: "relay",
                                  lastConnected: when, statusMessage: "在山上", statusUpdatedAt: when)
        let back = try JSONDecoder().decode(DeviceRecord.self, from: try JSONEncoder().encode(record))
        XCTAssertEqual(back.statusMessage, "在山上")
        XCTAssertEqual(back.statusUpdatedAt, when)
        XCTAssertEqual(back, record)
    }

    func testMergeKeepsNewerStatus() {
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        var a = DeviceRecord(id: "a", displayName: "C", sourceType: "bonjour", lastConnected: old,
                             statusMessage: "舊", statusUpdatedAt: old)
        a.merge(with: DeviceRecord(id: "b", displayName: "C", sourceType: "bonjour", lastConnected: old,
                                   statusMessage: "新", statusUpdatedAt: new))
        XCTAssertEqual(a.statusMessage, "新")
        XCTAssertEqual(a.statusUpdatedAt, new)

        // An older (or absent) status never overwrites a newer one, including a
        // newer cleared (nil-text) status.
        var b = DeviceRecord(id: "a", displayName: "C", sourceType: "bonjour", lastConnected: old,
                             statusMessage: nil, statusUpdatedAt: new)
        b.merge(with: DeviceRecord(id: "b", displayName: "C", sourceType: "bonjour", lastConnected: old,
                                   statusMessage: "舊", statusUpdatedAt: old))
        XCTAssertNil(b.statusMessage)
        XCTAssertEqual(b.statusUpdatedAt, new)
        b.merge(with: DeviceRecord(id: "c", displayName: "C", sourceType: "bonjour", lastConnected: old))
        XCTAssertEqual(b.statusUpdatedAt, new)

        var c = DeviceRecord(id: "a", displayName: "C", sourceType: "bonjour", lastConnected: old)
        c.merge(with: DeviceRecord(id: "b", displayName: "C", sourceType: "bonjour", lastConnected: old,
                                   statusMessage: "有", statusUpdatedAt: old))
        XCTAssertEqual(c.statusMessage, "有")
    }

    func testSetStatusUpdatesOnlyMatchingRecordsAndNeverInserts() {
        let keyDir = FileManager.default.temporaryDirectory.appendingPathComponent("drst-\(UUID().uuidString)")
        PeerDropPersistence.fileStore = .init(directory: keyDir, namespace: "drsttest")
        UserDefaults.standard.set(false, forKey: "peerDropClipboardSyncEnabled")
        let cm = ConnectionManager()
        let saved = cm.deviceStore.records
        defer {
            cm.deviceStore.replaceAll(with: saved)
            cm.deviceStore.saveImmediately()
            UserDefaults.standard.removeObject(forKey: "peerDropClipboardSyncEnabled")
            PeerDropPersistence.fileStore = nil
            try? FileManager.default.removeItem(at: keyDir)
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        cm.deviceStore.replaceAll(with: [
            DeviceRecord(id: "r1", displayName: "One", sourceType: "bonjour", lastConnected: now),
            DeviceRecord(id: "r2", displayName: "Two", sourceType: "relay", lastConnected: now),
            DeviceRecord(id: "r3", displayName: "Three", sourceType: "bonjour", lastConnected: now,
                         statusMessage: "別人的", statusUpdatedAt: now),
        ])
        cm.deviceStore.setStatus("在山上", updatedAt: now, forRecordIDs: ["r1", "r2", "missing"])
        let byID = Dictionary(uniqueKeysWithValues: cm.deviceStore.records.map { ($0.id, $0) })
        XCTAssertEqual(cm.deviceStore.records.count, 3, "never inserts")
        XCTAssertEqual(byID["r1"]?.statusMessage, "在山上")
        XCTAssertEqual(byID["r1"]?.statusUpdatedAt, now)
        XCTAssertEqual(byID["r2"]?.statusMessage, "在山上")
        XCTAssertEqual(byID["r3"]?.statusMessage, "別人的", "untouched")

        cm.deviceStore.setStatus(nil, updatedAt: now.addingTimeInterval(1), forRecordIDs: ["r1"])
        XCTAssertNil(cm.deviceStore.records.first { $0.id == "r1" }?.statusMessage)
        XCTAssertEqual(cm.deviceStore.records.first { $0.id == "r1" }?.statusUpdatedAt, now.addingTimeInterval(1))

        cm.deviceStore.setStatus("x", updatedAt: now, forRecordIDs: ["nope"])
        XCTAssertEqual(cm.deviceStore.records.count, 3)
        XCTAssertFalse(cm.deviceStore.records.contains { $0.statusMessage == "x" })
    }
}
