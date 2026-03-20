import XCTest
@testable import PeerDrop

final class ICEConfigurationTests: XCTestCase {

    func testSTUNServers() {
        let servers = ICEConfigurationProvider.stunServers
        XCTAssertEqual(servers.count, 2)
    }

    func testIceServersFromCredentials() {
        let credentials = ICECredentials(
            username: "testuser",
            credential: "testpass",
            urls: ["turn:turn.example.com:3478"],
            ttl: 900
        )
        let servers = ICEConfigurationProvider.iceServers(from: credentials)
        // 2 STUN + 1 TURN
        XCTAssertEqual(servers.count, 3)
    }

    func testDefaultConfiguration() {
        let config = ICEConfigurationProvider.defaultConfiguration()
        XCTAssertEqual(config.iceServers.count, 2)
        XCTAssertEqual(config.sdpSemantics, .unifiedPlan)
        XCTAssertEqual(config.iceTransportPolicy, .all)
    }

    func testConfigurationWithCredentials() {
        let credentials = ICECredentials(
            username: "user",
            credential: "pass",
            urls: ["turn:turn.cf.com:3478", "turns:turn.cf.com:5349"],
            ttl: 900
        )
        let config = ICEConfigurationProvider.configuration(with: credentials)
        XCTAssertEqual(config.iceServers.count, 3) // 2 STUN + 1 TURN
        XCTAssertEqual(config.sdpSemantics, .unifiedPlan)
    }

    func testICECredentialsCodable() throws {
        let original = ICECredentials(
            username: "testuser",
            credential: "testcred",
            urls: ["turn:example.com:3478"],
            ttl: 900
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ICECredentials.self, from: data)

        XCTAssertEqual(decoded.username, original.username)
        XCTAssertEqual(decoded.credential, original.credential)
        XCTAssertEqual(decoded.urls, original.urls)
        XCTAssertEqual(decoded.ttl, original.ttl)
    }
}
