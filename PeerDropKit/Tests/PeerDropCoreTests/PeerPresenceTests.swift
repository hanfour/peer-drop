import XCTest
@testable import PeerDropCore

final class PeerPresenceTests: XCTestCase {
    private func resolve(_ ids: Set<String>, connected: Set<String> = [], connecting: Set<String> = [],
                         discovered: Set<String> = [], server: Set<String> = []) -> PeerPresence {
        PeerPresenceResolver.presence(
            ids: ids,
            sources: PresenceSources(connected: connected, connecting: connecting, discovered: discovered, server: server))
    }

    func testConnectedWins() {
        XCTAssertEqual(resolve(["a"], connected: ["a"], discovered: ["a"]), .online)
    }
    func testConnectedByAliasIdentityID() {
        XCTAssertEqual(resolve(["rec-1", "identity-1"], connected: ["identity-1"]), .online)
    }
    func testRelayKeyDoesNotMatchButIdentityDoes() {
        XCTAssertEqual(resolve(["uuid-1"], connected: ["relay-ab", "uuid-1"]), .online)
    }
    func testConnectingIsNearby() {
        XCTAssertEqual(resolve(["a"], connecting: ["a"]), .nearby)
    }
    func testDiscoveredOnlyIsNearby() {
        XCTAssertEqual(resolve(["a"], discovered: ["a"]), .nearby)
    }
    func testNothingIsOffline() {
        XCTAssertEqual(resolve(["a"], connected: ["b"], connecting: ["c"], discovered: ["d"]), .offline)
    }
    func testEmptyIDsIsOffline() {
        XCTAssertEqual(resolve([], connected: ["a"], discovered: ["a"]), .offline)
    }
    func testServerSourceCountsAsOnline() {
        XCTAssertEqual(resolve(["a"], server: ["a"]), .online)
    }
    func testRelayKeyAloneDoesNotMatchRecord() {
        XCTAssertEqual(resolve(["uuid-1"], connected: ["relay-ab"]), .offline)
    }

    // MARK: - RecordConnectionLookup

    func testLookupPrefersRecordID() {
        let map = ["rec": 1, "alias": 2]
        XCTAssertEqual(RecordConnectionLookup.resolve(recordID: "rec", peerDeviceID: "alias") { map[$0] }, 1)
    }

    func testLookupFallsBackToPeerDeviceID() {
        let map = ["alias": 2]
        XCTAssertEqual(RecordConnectionLookup.resolve(recordID: "rec", peerDeviceID: "alias") { map[$0] }, 2)
    }

    func testLookupMissesWhenNeitherMatches() {
        let map = ["other": 3]
        XCTAssertNil(RecordConnectionLookup.resolve(recordID: "rec", peerDeviceID: "alias") { map[$0] })
        XCTAssertNil(RecordConnectionLookup.resolve(recordID: "rec", peerDeviceID: nil) { map[$0] })
    }
}
