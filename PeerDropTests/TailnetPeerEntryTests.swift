import XCTest
@testable import PeerDrop

final class TailnetPeerEntryTests: XCTestCase {
    func test_encodesDecodesAllFields() throws {
        let e = TailnetPeerEntry(
            id: UUID(), displayName: "Alice's iPad",
            ip: "100.64.1.23", port: 9876,
            lastReachable: Date(timeIntervalSince1970: 1_700_000_000),
            lastChecked: Date(timeIntervalSince1970: 1_700_000_100),
            consecutiveFailures: 0, addedAt: Date(timeIntervalSince1970: 1_600_000_000))
        let data = try JSONEncoder().encode(e)
        let back = try JSONDecoder().decode(TailnetPeerEntry.self, from: data)
        XCTAssertEqual(back.id, e.id)
        XCTAssertEqual(back.ip, "100.64.1.23")
        XCTAssertEqual(back.consecutiveFailures, 0)
    }

    func test_decodeLegacyEntryMissingConsecutiveFailures_defaultsToZero() throws {
        let legacy = #"{"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","displayName":"Legacy","ip":"100.64.1.1","port":9876,"addedAt":1700000000}"#
        let data = legacy.data(using: .utf8)!
        let e = try JSONDecoder().decode(TailnetPeerEntry.self, from: data)
        XCTAssertEqual(e.consecutiveFailures, 0)
    }
}
