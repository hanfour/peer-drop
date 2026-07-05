import XCTest
import Foundation
@testable import PeerDropSecurity

final class CryptoMetricsPayloadTests: XCTestCase {

    func test_emptySnapshotProducesNilPayload() {
        let snapshot = CryptoHardeningMetrics().snapshot()
        XCTAssertNil(CryptoMetricsPayload(snapshot: snapshot, platform: "ios", appVersion: "5.6.0",
                                          timestamp: Date(timeIntervalSince1970: 0)),
                     "an empty snapshot must not be uploaded — nothing to report")
    }

    func test_payloadCarriesFlatAndKeyedCounters() throws {
        let m = CryptoHardeningMetrics()
        m.record(.c1SpkTimestampValid, peerVersion: .v5_4_plus)
        m.record(.c1SpkTimestampValid, peerVersion: .legacy)
        m.record(.policySignatureInvalid, peerVersion: .v5_4_plus)

        let payload = try XCTUnwrap(CryptoMetricsPayload(
            snapshot: m.snapshot(), platform: "ios", appVersion: "5.6.0",
            timestamp: Date(timeIntervalSince1970: 0)))

        XCTAssertEqual(payload.counters["c1.spk_timestamp_valid"], 2)
        XCTAssertEqual(payload.counters["policy.signature_invalid"], 1)
        XCTAssertEqual(payload.platform, "ios")
        XCTAssertEqual(payload.appVersion, "5.6.0")

        // keyedCounters retains the per-peer-version dimension.
        let keyed = Set(payload.keyedCounters.map { "\($0.kind)|\($0.peerVersion ?? "nil")|\($0.count)" })
        XCTAssertTrue(keyed.contains("c1.spk_timestamp_valid|v5_4_plus|1"))
        XCTAssertTrue(keyed.contains("c1.spk_timestamp_valid|legacy|1"))
    }

    func test_payloadEncodesToWorkerJSONShape() throws {
        let m = CryptoHardeningMetrics()
        m.record(.c2OpkFailedInitiation, peerVersion: .v5_4_plus)
        let payload = try XCTUnwrap(CryptoMetricsPayload(
            snapshot: m.snapshot(), platform: "ios", appVersion: "5.6.0",
            timestamp: Date(timeIntervalSince1970: 0)))

        let data = try JSONEncoder().encode(payload)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        // Worker requires a `counters` object; these are the fields it reads.
        let counters = try XCTUnwrap(obj["counters"] as? [String: Int])
        XCTAssertEqual(counters["c2.opk_failed_initiation"], 1)
        XCTAssertNotNil(obj["keyedCounters"])
        XCTAssertEqual(obj["platform"] as? String, "ios")
        XCTAssertEqual(obj["appVersion"] as? String, "5.6.0")
    }
}
