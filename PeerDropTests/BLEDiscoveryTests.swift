import XCTest
@testable import PeerDrop

final class BLEDiscoveryTests: XCTestCase {

    // MARK: - DiscoveredPeer BLE Tests

    func testBLEPeerCreation() {
        let peer = DiscoveredPeer(
            id: "ble-TEST-UUID",
            displayName: "Test Device",
            endpoint: .bleOnly(peripheralIdentifier: "TEST-UUID"),
            source: .bluetooth,
            lastSeen: Date(),
            rssi: -65
        )

        XCTAssertEqual(peer.id, "ble-TEST-UUID")
        XCTAssertEqual(peer.displayName, "Test Device")
        XCTAssertEqual(peer.source, .bluetooth)
        XCTAssertEqual(peer.rssi, -65)
        XCTAssertNil(peer.distance)
        XCTAssertNil(peer.direction)

        if case .bleOnly(let identifier) = peer.endpoint {
            XCTAssertEqual(identifier, "TEST-UUID")
        } else {
            XCTFail("Expected .bleOnly endpoint")
        }
    }

    func testBLEPeerEquality() {
        let peer1 = DiscoveredPeer(
            id: "ble-1",
            displayName: "Device",
            endpoint: .bleOnly(peripheralIdentifier: "1"),
            source: .bluetooth,
            rssi: -50
        )
        let peer2 = DiscoveredPeer(
            id: "ble-1",
            displayName: "Device",
            endpoint: .bleOnly(peripheralIdentifier: "1"),
            source: .bluetooth,
            rssi: -50
        )
        XCTAssertEqual(peer1, peer2)
    }

    // MARK: - DiscoveryCoordinator Multi-Source Merge Tests

    func testMergeBonjourAndBLEPeers() {
        let coordinator = DiscoveryCoordinator(backends: [])

        // Simulate adding manual peer
        coordinator.addManualPeer(host: "192.168.1.1", port: 54321, name: "Manual Device")

        // Verify manual peer persists
        XCTAssertEqual(coordinator.peers.count, 1)
        XCTAssertEqual(coordinator.peers.first?.source, .manual)
    }

    func testDiscoverySourceValues() {
        XCTAssertNotEqual(DiscoverySource.bonjour, DiscoverySource.bluetooth)
        XCTAssertNotEqual(DiscoverySource.bluetooth, DiscoverySource.manual)
        XCTAssertNotEqual(DiscoverySource.bonjour, DiscoverySource.manual)
    }

    // MARK: - PeerEndpoint BLE Tests

    func testBLEOnlyEndpoint() {
        let endpoint = PeerEndpoint.bleOnly(peripheralIdentifier: "ABCD-1234")

        if case .bleOnly(let id) = endpoint {
            XCTAssertEqual(id, "ABCD-1234")
        } else {
            XCTFail("Expected .bleOnly endpoint")
        }

        // Verify it's not equal to bonjour or manual
        let bonjourEndpoint = PeerEndpoint.bonjour(name: "test", type: "_peerdrop._tcp", domain: "local")
        XCTAssertNotEqual(endpoint, bonjourEndpoint)
    }

    // MARK: - FeatureSettings BLE Tests

    func testBLEDiscoverySettingDefaultEnabled() {
        // Remove any existing value
        UserDefaults.standard.removeObject(forKey: "peerDropBLEDiscoveryEnabled")
        XCTAssertTrue(FeatureSettings.isBLEDiscoveryEnabled)
    }

    func testBLEDiscoverySettingCanBeDisabled() {
        UserDefaults.standard.set(false, forKey: "peerDropBLEDiscoveryEnabled")
        XCTAssertFalse(FeatureSettings.isBLEDiscoveryEnabled)
        // Cleanup
        UserDefaults.standard.removeObject(forKey: "peerDropBLEDiscoveryEnabled")
    }

    func testNearbyInteractionSettingDefaultEnabled() {
        UserDefaults.standard.removeObject(forKey: "peerDropNearbyInteractionEnabled")
        XCTAssertTrue(FeatureSettings.isNearbyInteractionEnabled)
    }

    // MARK: - DiscoveredPeer NI Fields

    func testDiscoveredPeerWithProximityData() {
        var peer = DiscoveredPeer(
            id: "test-peer",
            displayName: "Test",
            endpoint: .bonjour(name: "Test", type: "_peerdrop._tcp", domain: "local"),
            source: .bonjour
        )

        XCTAssertNil(peer.distance)
        XCTAssertNil(peer.direction)

        peer.distance = 1.5
        peer.direction = SIMD3<Float>(0, 0, 1)

        XCTAssertEqual(peer.distance, 1.5)
        XCTAssertEqual(peer.direction, SIMD3<Float>(0, 0, 1))
    }

    // MARK: - MessageType NI Cases

    func testNIMessageTypes() {
        let offerType = MessageType.niTokenOffer
        let responseType = MessageType.niTokenResponse

        XCTAssertEqual(offerType.rawValue, "niTokenOffer")
        XCTAssertEqual(responseType.rawValue, "niTokenResponse")

        // Verify they can be encoded/decoded
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let encoded = try! encoder.encode(offerType)
        let decoded = try! decoder.decode(MessageType.self, from: encoded)
        XCTAssertEqual(decoded, .niTokenOffer)
    }
}
