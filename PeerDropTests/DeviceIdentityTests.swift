import XCTest
@testable import PeerDrop

final class DeviceIdentityTests: XCTestCase {
    func test_deviceId_isStableAcrossCalls() {
        UserDefaults.standard.removeObject(forKey: "peerDropDeviceId")
        let first = DeviceIdentity.deviceId
        let second = DeviceIdentity.deviceId
        XCTAssertEqual(first, second)
        XCTAssertFalse(first.isEmpty)
        XCTAssertGreaterThanOrEqual(first.count, 16)
    }

    func test_deviceId_matchesExpectedFormat() {
        UserDefaults.standard.removeObject(forKey: "peerDropDeviceId")
        let id = DeviceIdentity.deviceId
        // UUID string like D1234567-89AB-CDEF-...
        XCTAssertTrue(id.range(of: "^[A-F0-9-]{36}$", options: .regularExpression) != nil)
    }
}
