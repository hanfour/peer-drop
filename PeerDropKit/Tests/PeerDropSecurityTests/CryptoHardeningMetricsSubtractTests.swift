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

/// Persistence so undelivered counters survive OS termination — closing
/// the at-least-once gap (a background POST that fails, then the OS kills
/// the suspended app, must not silently lose error signals).
final class CryptoHardeningMetricsPersistenceTests: XCTestCase {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("crypto-metrics-\(UUID().uuidString).json")
    }

    func test_persistThenLoadRestoresCounters() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let m = CryptoHardeningMetrics(persistenceURL: url)
        m.record(.c2OpkFailedInitiation, peerVersion: .v5_4_plus)
        m.record(.c2OpkFailedInitiation, peerVersion: .v5_4_plus)
        m.persist()

        // A fresh instance (models a relaunch) loads the residual.
        let reloaded = CryptoHardeningMetrics(persistenceURL: url)
        XCTAssertEqual(reloaded.snapshot().counters["c2.opk_failed_initiation"], 2)
    }

    func test_persistWritesResidualAfterSubtract() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let m = CryptoHardeningMetrics(persistenceURL: url)
        m.record(.c1SpkTimestampValid, peerVersion: .v5_4_plus)
        m.record(.policySignatureInvalid, peerVersion: .v5_4_plus)
        let delivered = m.snapshot()
        m.record(.c1SpkTimestampValid, peerVersion: .v5_4_plus) // concurrent
        m.subtract(delivered) // upload succeeded for `delivered`
        m.persist()

        // Only the concurrent (undelivered) event survives to the next launch.
        let reloaded = CryptoHardeningMetrics(persistenceURL: url)
        XCTAssertEqual(reloaded.snapshot().counters["c1.spk_timestamp_valid"], 1)
        XCTAssertNil(reloaded.snapshot().counters["policy.signature_invalid"])
    }

    func test_nilPersistenceURLIsNoOp() {
        let m = CryptoHardeningMetrics() // default init, no persistence
        m.record(.c1SpkTimestampValid, peerVersion: .v5_4_plus)
        m.persist() // must not crash
        XCTAssertEqual(m.snapshot().counters["c1.spk_timestamp_valid"], 1)
    }
}
