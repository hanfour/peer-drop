import XCTest
@testable import PeerDrop

final class CryptoHardeningMetricsTests: XCTestCase {

    func test_recordIncrementsCounter() {
        let m = CryptoHardeningMetrics()
        m.record(.c1SpkTimestampValid, peerVersion: .v5_4_plus)
        m.record(.c1SpkTimestampValid, peerVersion: .v5_4_plus)
        m.record(.c1SpkTimestampTooOld, peerVersion: .legacy)
        let snapshot = m.snapshot()
        XCTAssertEqual(snapshot.counters["c1.spk_timestamp_valid"], 2)
        XCTAssertEqual(snapshot.counters["c1.spk_timestamp_too_old"], 1)
    }

    func test_eventKindCount_is_23() {
        XCTAssertEqual(CryptoHardeningMetrics.EventKind.allCases.count, 23,
                       "Spec §8.1 baseline 22 events + 1 added in PR4 review (policy.invariant_violation)")
    }

    func test_recordIncrements_perPeerVersion() {
        let m = CryptoHardeningMetrics()
        m.record(.c1SpkTimestampValid, peerVersion: .v5_4_plus)
        m.record(.c1SpkTimestampValid, peerVersion: .legacy)
        let snap = m.snapshot()
        XCTAssertEqual(snap.counters["c1.spk_timestamp_valid"], 2)
        XCTAssertEqual(
            snap.keyedCounters[.init(kind: "c1.spk_timestamp_valid", peerVersion: "v5_4_plus")],
            1
        )
        XCTAssertEqual(
            snap.keyedCounters[.init(kind: "c1.spk_timestamp_valid", peerVersion: "legacy")],
            1
        )
    }
}
