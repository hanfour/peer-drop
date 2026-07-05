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
}
