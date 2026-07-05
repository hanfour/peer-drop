import XCTest
@testable import PeerDropCore
@testable import PeerDropSecurity

final class CryptoMetricsUploaderTests: XCTestCase {

    func test_emptySnapshotIsNotSent() async {
        let metrics = CryptoHardeningMetrics()
        var sendCount = 0
        let uploader = CryptoMetricsUploader(appVersion: "5.6.0") { _ in
            sendCount += 1
            return 201
        }
        await uploader.flush(metrics: metrics)
        XCTAssertEqual(sendCount, 0, "an empty snapshot must not POST")
    }

    func test_successfulUploadSubtractsDeliveredCounts() async {
        let metrics = CryptoHardeningMetrics()
        metrics.record(.c1SpkTimestampValid, peerVersion: .v5_4_plus)
        metrics.record(.policySignatureInvalid, peerVersion: .v5_4_plus)

        var sentBody: Data?
        let uploader = CryptoMetricsUploader(appVersion: "5.6.0") { body in
            sentBody = body
            return 201
        }
        await uploader.flush(metrics: metrics)

        XCTAssertNotNil(sentBody)
        // Delivered counts removed on success.
        XCTAssertTrue(metrics.snapshot().counters.isEmpty)
    }

    func test_failedUploadRetainsCountsForRetry() async {
        let metrics = CryptoHardeningMetrics()
        metrics.record(.c2OpkFailedInitiation, peerVersion: .v5_4_plus)

        let uploader = CryptoMetricsUploader(appVersion: "5.6.0") { _ in
            500 // server error
        }
        await uploader.flush(metrics: metrics)

        // Not subtracted — the error-counter signal survives to retry.
        XCTAssertEqual(metrics.snapshot().counters["c2.opk_failed_initiation"], 1)
    }

    func test_noCredentialResultIsTreatedAsFailure() async {
        let metrics = CryptoHardeningMetrics()
        metrics.record(.c2OpkFailedInitiation, peerVersion: .v5_4_plus)

        // nil status models "couldn't send" (no credential / network down).
        let uploader = CryptoMetricsUploader(appVersion: "5.6.0") { _ in nil }
        await uploader.flush(metrics: metrics)

        XCTAssertEqual(metrics.snapshot().counters["c2.opk_failed_initiation"], 1)
    }

    /// A permanent client error (413 payload-too-large, 400 bad request)
    /// can never succeed on retry — the uploader must DROP those counts, not
    /// re-POST the same body forever (which would silently wedge the busiest
    /// devices out of the soak).
    func test_permanentClientErrorDropsCountsInsteadOfLooping() async {
        let metrics = CryptoHardeningMetrics()
        metrics.record(.c1SpkTimestampValid, peerVersion: .v5_4_plus)

        let uploader = CryptoMetricsUploader(appVersion: "5.6.0") { _ in 413 }
        await uploader.flush(metrics: metrics)

        XCTAssertTrue(metrics.snapshot().counters.isEmpty,
                      "413 is non-retryable — counts must be dropped, not looped")
    }

    /// A transient 5xx / 401 must still RETAIN (retry next flush).
    func test_transientServerErrorRetains() async {
        let metrics = CryptoHardeningMetrics()
        metrics.record(.c2OpkFailedInitiation, peerVersion: .v5_4_plus)

        let uploader = CryptoMetricsUploader(appVersion: "5.6.0") { _ in 503 }
        await uploader.flush(metrics: metrics)

        XCTAssertEqual(metrics.snapshot().counters["c2.opk_failed_initiation"], 1)
    }

    /// Concurrent flushes must not POST the same un-subtracted snapshot twice
    /// (server-side double-count). A reentrancy guard serializes them.
    func test_concurrentFlushesDoNotDoublePost() async {
        let metrics = CryptoHardeningMetrics()
        metrics.record(.c1SpkTimestampValid, peerVersion: .v5_4_plus)

        actor Counter { var n = 0; func bump() { n += 1 }; func get() -> Int { n } }
        let sendCount = Counter()
        let uploader = CryptoMetricsUploader(appVersion: "5.6.0") { _ in
            await sendCount.bump()
            try? await Task.sleep(nanoseconds: 50_000_000) // hold the in-flight window open
            return 201
        }

        async let a: Void = uploader.flush(metrics: metrics)
        async let b: Void = uploader.flush(metrics: metrics)
        _ = await (a, b)

        let n = await sendCount.get()
        XCTAssertEqual(n, 1, "a reentrant flush must not POST the same counts again")
    }
}
