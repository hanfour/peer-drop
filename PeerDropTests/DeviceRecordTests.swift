import XCTest
@testable import PeerDrop

final class DeviceRecordTests: XCTestCase {
    func test_deviceRecord_encodesDecodesNewField() throws {
        let record = DeviceRecord(
            id: "test",
            displayName: "Test",
            sourceType: "relay",
            lastConnected: Date(timeIntervalSince1970: 1_700_000_000),
            connectionCount: 1,
            peerDeviceId: "ABCDEF-1234"
        )
        let data = try JSONEncoder().encode(record)
        let back = try JSONDecoder().decode(DeviceRecord.self, from: data)
        XCTAssertEqual(back.peerDeviceId, "ABCDEF-1234")
    }

    func test_deviceRecord_decodesLegacyJSONWithoutPeerDeviceId() throws {
        // Legacy encoded record without peerDeviceId should still decode.
        let legacyJSON = #"""
        {"id":"legacy","displayName":"Legacy","sourceType":"relay","lastConnected":1700000000,"connectionCount":2,"connectionHistory":[]}
        """#
        let data = legacyJSON.data(using: .utf8)!
        let record = try JSONDecoder().decode(DeviceRecord.self, from: data)
        XCTAssertNil(record.peerDeviceId)
        XCTAssertEqual(record.id, "legacy")
    }
}
