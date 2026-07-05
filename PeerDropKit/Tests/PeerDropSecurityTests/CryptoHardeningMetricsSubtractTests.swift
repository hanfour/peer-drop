import XCTest
@testable import PeerDropSecurity

/// `subtract(_:)` supports at-least-once soak delivery: the uploader
/// snapshots, POSTs, and only on success removes exactly the delivered
/// counts — so events that arrived during the in-flight POST are retained,
/// and a failed POST re-sends its counters next flush (safe bias: never
/// silently lose an error-counter signal).
final class CryptoHardeningMetricsSubtractTests: XCTestCase {

    func test_subtractRemovesExactlyTheDeliveredCounts() {
        let m = CryptoHardeningMetrics()
        m.record(.c1SpkTimestampValid, peerVersion: .v5_4_plus)
        m.record(.c1SpkTimestampValid, peerVersion: .v5_4_plus)
        let delivered = m.snapshot()

        // A new event arrives during the "in-flight POST".
        m.record(.c1SpkTimestampValid, peerVersion: .v5_4_plus)

        m.subtract(delivered)

        // The 2 delivered are gone; the 1 concurrent event survives.
        XCTAssertEqual(m.snapshot().counters["c1.spk_timestamp_valid"], 1)
    }

    func test_subtractClampsAtZeroAndRemovesEmptyKeys() {
        let m = CryptoHardeningMetrics()
        m.record(.policySignatureInvalid, peerVersion: .v5_4_plus)
        let delivered = m.snapshot()
        m.subtract(delivered)
        m.subtract(delivered) // double subtract must not go negative
        XCTAssertNil(m.snapshot().counters["policy.signature_invalid"])
    }
}
