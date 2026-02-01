import XCTest
@testable import PeerDrop

@MainActor
final class DeviceRecordStoreTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "peerDropDeviceRecords")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "peerDropDeviceRecords")
        super.tearDown()
    }

    func testAddNewRecord() {
        let store = DeviceRecordStore()
        store.addOrUpdate(id: "peer1", displayName: "iPhone", sourceType: "bonjour", host: nil, port: nil)
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records[0].displayName, "iPhone")
        XCTAssertEqual(store.records[0].connectionCount, 1)
    }

    func testUpdateExistingRecord() {
        let store = DeviceRecordStore()
        store.addOrUpdate(id: "peer1", displayName: "iPhone", sourceType: "bonjour", host: nil, port: nil)
        store.addOrUpdate(id: "peer1", displayName: "iPhone 15", sourceType: "bonjour", host: nil, port: nil)
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records[0].displayName, "iPhone 15")
        XCTAssertEqual(store.records[0].connectionCount, 2)
    }

    func testRemoveRecord() {
        let store = DeviceRecordStore()
        store.addOrUpdate(id: "peer1", displayName: "iPhone", sourceType: "bonjour", host: nil, port: nil)
        store.remove(id: "peer1")
        XCTAssertTrue(store.records.isEmpty)
    }

    func testPersistence() {
        let store1 = DeviceRecordStore()
        store1.addOrUpdate(id: "peer1", displayName: "iPhone", sourceType: "bonjour", host: nil, port: nil)
        let store2 = DeviceRecordStore()
        XCTAssertEqual(store2.records.count, 1)
        XCTAssertEqual(store2.records[0].displayName, "iPhone")
    }

    func testSortByName() {
        let store = DeviceRecordStore()
        store.addOrUpdate(id: "b", displayName: "Bravo", sourceType: "bonjour", host: nil, port: nil)
        store.addOrUpdate(id: "a", displayName: "Alpha", sourceType: "bonjour", host: nil, port: nil)
        let sorted = store.sorted(by: .name)
        XCTAssertEqual(sorted[0].displayName, "Alpha")
        XCTAssertEqual(sorted[1].displayName, "Bravo")
    }

    func testSortByConnectionCount() {
        let store = DeviceRecordStore()
        store.addOrUpdate(id: "a", displayName: "Alpha", sourceType: "bonjour", host: nil, port: nil)
        store.addOrUpdate(id: "b", displayName: "Bravo", sourceType: "bonjour", host: nil, port: nil)
        store.addOrUpdate(id: "b", displayName: "Bravo", sourceType: "bonjour", host: nil, port: nil)
        let sorted = store.sorted(by: .connectionCount)
        XCTAssertEqual(sorted[0].displayName, "Bravo")
    }

    func testSearchFilter() {
        let store = DeviceRecordStore()
        store.addOrUpdate(id: "a", displayName: "iPhone 15", sourceType: "bonjour", host: nil, port: nil)
        store.addOrUpdate(id: "b", displayName: "MacBook", sourceType: "manual", host: "10.0.0.1", port: 9000)
        XCTAssertEqual(store.search(query: "mac").count, 1)
        XCTAssertEqual(store.search(query: "").count, 2)
    }

    func testManualPeerStoresHostPort() {
        let store = DeviceRecordStore()
        store.addOrUpdate(id: "10.0.0.1:9000", displayName: "Server", sourceType: "manual", host: "10.0.0.1", port: 9000)
        XCTAssertEqual(store.records[0].host, "10.0.0.1")
        XCTAssertEqual(store.records[0].port, 9000)
    }
}
