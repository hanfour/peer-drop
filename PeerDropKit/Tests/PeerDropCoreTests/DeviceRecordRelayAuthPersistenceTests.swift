// PeerDropKit/Tests/PeerDropCoreTests/DeviceRecordRelayAuthPersistenceTests.swift
//
// Relay-auth TOFU pins must persist immediately, not on a 500ms debounce that
// a crash in the window would lose. setFingerprint / addNewDevice previously
// only mutated the in-memory array.
import XCTest
@testable import PeerDropCore
import PeerDropSecurity

final class DeviceRecordRelayAuthPersistenceTests: XCTestCase {
    private let key = "peerDropDeviceRecords"

    @MainActor
    func test_setFingerprint_persistsPinImmediately() {
        UserDefaults.standard.removeObject(forKey: key)
        let store = DeviceRecordStore()
        store.replaceAll(with: [
            DeviceRecord(id: "P", displayName: "Peer", sourceType: "relay",
                         lastConnected: Date(timeIntervalSince1970: 1))
        ])

        store.setFingerprint("FP-RELAY", for: "P")

        // A crash right here must not lose the pin: a fresh store loads from disk.
        let reloaded = DeviceRecordStore()
        XCTAssertEqual(reloaded.deviceRecord(for: "P")?.certificateFingerprint, "FP-RELAY")
    }

    @MainActor
    func test_addNewDevice_persistsPinImmediately() {
        UserDefaults.standard.removeObject(forKey: key)
        let store = DeviceRecordStore()
        var device = RelayAuthNewDevice(
            id: "NEW", displayName: "NEW", sourceType: "relay",
            host: nil, port: nil, lastConnected: Date(timeIntervalSince1970: 2),
            connectionCount: 1, connectionHistory: [Date(timeIntervalSince1970: 2)]
        )
        device.certificateFingerprint = "FP-NEW"

        store.addNewDevice(device)

        let reloaded = DeviceRecordStore()
        XCTAssertEqual(reloaded.deviceRecord(for: "NEW")?.certificateFingerprint, "FP-NEW")
    }
}
