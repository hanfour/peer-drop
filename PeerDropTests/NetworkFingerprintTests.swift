import XCTest
@testable import PeerDrop

final class NetworkFingerprintTests: XCTestCase {

    // MARK: - NetworkFingerprint

    func test_sameSubnetAndGateway_yieldsSameFingerprint() {
        let a = NetworkFingerprint.fingerprint(subnet: "192.168.1.0/24", gateway: "192.168.1.1")
        let b = NetworkFingerprint.fingerprint(subnet: "192.168.1.0/24", gateway: "192.168.1.1")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 8)
    }

    func test_differentGateway_yieldsDifferentFingerprint() {
        let a = NetworkFingerprint.fingerprint(subnet: "192.168.1.0/24", gateway: "192.168.1.1")
        let b = NetworkFingerprint.fingerprint(subnet: "192.168.1.0/24", gateway: "192.168.1.254")
        XCTAssertNotEqual(a, b)
    }

    func test_differentSubnet_yieldsDifferentFingerprint() {
        let a = NetworkFingerprint.fingerprint(subnet: "192.168.1.0/24", gateway: "192.168.1.1")
        let b = NetworkFingerprint.fingerprint(subnet: "10.0.0.0/8", gateway: "192.168.1.1")
        XCTAssertNotEqual(a, b)
    }

    func test_fingerprint_isExactly8HexChars() {
        let fp = NetworkFingerprint.fingerprint(subnet: "10.0.0.0/8", gateway: "10.0.0.1")
        XCTAssertEqual(fp.count, 8)
        XCTAssertTrue(fp.allSatisfy { $0.isHexDigit })
    }

    // MARK: - RelayHintsStore

    private let hintsKey = "peerDropRelayHints"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: hintsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: hintsKey)
        super.tearDown()
    }

    func test_shouldPreferRelay_returnsFalse_whenNoRecords() {
        let store = RelayHintsStore()
        XCTAssertFalse(store.shouldPreferRelay(fingerprint: "aabbccdd"))
    }

    func test_shouldPreferRelay_returnsFalse_afterTwoPhase2Records() {
        let store = RelayHintsStore()
        let fp = "aabbccdd"
        store.recordPhase2Save(fingerprint: fp)
        store.recordPhase2Save(fingerprint: fp)
        XCTAssertFalse(store.shouldPreferRelay(fingerprint: fp))
    }

    func test_shouldPreferRelay_returnsTrue_afterThreePhase2Records() {
        let store = RelayHintsStore()
        let fp = "aabbccdd"
        store.recordPhase2Save(fingerprint: fp)
        store.recordPhase2Save(fingerprint: fp)
        store.recordPhase2Save(fingerprint: fp)
        XCTAssertTrue(store.shouldPreferRelay(fingerprint: fp))
    }

    func test_recordPhase1Success_resetsCounter() {
        let store = RelayHintsStore()
        let fp = "aabbccdd"
        store.recordPhase2Save(fingerprint: fp)
        store.recordPhase2Save(fingerprint: fp)
        store.recordPhase2Save(fingerprint: fp)
        XCTAssertTrue(store.shouldPreferRelay(fingerprint: fp))

        store.recordPhase1Success(fingerprint: fp)
        XCTAssertFalse(store.shouldPreferRelay(fingerprint: fp))
    }
}
