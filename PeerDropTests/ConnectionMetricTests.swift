import XCTest
@testable import PeerDrop

final class ConnectionMetricTests: XCTestCase {
    func test_metricRoundTripsThroughCodable() throws {
        let m = ConnectionMetric(
            id: "abc",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            connectionType: .relayWorker,
            role: .joiner,
            outcome: .success,
            durationMs: 1234,
            iceStats: ConnectionMetric.ICEStats(
                candidatesGathered: [.host, .srflx, .relay],
                candidatesUsed: .relay,
                srflxGatherOrder: 1,
                relayGatherOrder: 2,
                firstConnectedMs: 900,
                phase1ConnectedMs: nil,
                phase2ConnectedMs: 1200,
                ipv6CandidateGathered: true,
                ipv6Connected: false
            ),
            platform: "ios",
            appVersion: "3.3.0",
            networkType: .wifi,
            hasTailscale: false,
            hasIPv6: true
        )
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(ConnectionMetric.self, from: data)
        XCTAssertEqual(back.id, m.id)
        XCTAssertEqual(back.iceStats?.candidatesGathered, [.host, .srflx, .relay])
        XCTAssertEqual(back.iceStats?.candidatesUsed, .relay)
    }

    func test_outcomeFailureSerializesWithReason() throws {
        let m = ConnectionMetric.withOutcome(.failure(reason: "timeout"))
        let data = try JSONEncoder().encode(m)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let outcome = json["outcome"] as! [String: Any]
        XCTAssertEqual(outcome["type"] as? String, "failure")
        XCTAssertEqual(outcome["reason"] as? String, "timeout")
    }

    func test_outcomeAbandonedSerializesWithoutReason() throws {
        let m = ConnectionMetric.withOutcome(.abandoned)
        let data = try JSONEncoder().encode(m)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let outcome = json["outcome"] as! [String: Any]
        XCTAssertEqual(outcome["type"] as? String, "abandoned")
        XCTAssertNil(outcome["reason"])
    }

    func test_iceStatsNilEncodesAsAbsent() throws {
        let m = ConnectionMetric.withOutcome(.success, iceStats: nil)
        let data = try JSONEncoder().encode(m)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        // Codable default: nil optional -> key absent.
        XCTAssertNil(json["iceStats"])
    }
}

// Test helper used by the short-form tests above.
extension ConnectionMetric {
    static func withOutcome(_ outcome: Outcome, iceStats: ICEStats? = nil) -> ConnectionMetric {
        ConnectionMetric(
            id: "x", timestamp: Date(), connectionType: .relayWorker, role: .joiner,
            outcome: outcome, durationMs: 0, iceStats: iceStats,
            platform: "ios", appVersion: "3.3.0", networkType: .unknown,
            hasTailscale: false, hasIPv6: false
        )
    }
}
