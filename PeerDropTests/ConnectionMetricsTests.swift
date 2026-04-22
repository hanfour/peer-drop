import XCTest
@testable import PeerDrop

@MainActor
final class ConnectionMetricsTests: XCTestCase {
    func test_tokenFinalizedWithSuccess_recordsMetric() async {
        let m = ConnectionMetrics(flushOnCount: 1)
        let token = await m.begin(type: .localBonjour, role: .initiator)
        await m.recordConnected(token, used: .host)
        let pending = await m.pendingCount
        let flushedCount = await m.lastFlushedCount
        let last = await m.lastFlushedMetric
        XCTAssertEqual(pending, 0) // flushed immediately when count reached 1
        XCTAssertEqual(flushedCount, 1)
        XCTAssertEqual(last?.connectionType, .localBonjour)
        XCTAssertEqual(last?.role, .initiator)
        if case .success = last?.outcome {} else { XCTFail("expected .success") }
        XCTAssertEqual(last?.iceStats?.candidatesUsed, .host)
    }

    func test_tokenDeinitsWithoutFinalize_recordsAbandoned() async {
        let m = ConnectionMetrics(flushOnCount: 1)
        do {
            _ = await m.begin(type: .relayWorker, role: .joiner)
        }
        // Wait for the deinit-scheduled Task to finalize via the actor.
        try? await Task.sleep(nanoseconds: 200_000_000)
        let flushedCount = await m.lastFlushedCount
        let last = await m.lastFlushedMetric
        XCTAssertEqual(flushedCount, 1)
        if case .abandoned = last?.outcome {} else { XCTFail("expected .abandoned") }
    }

    func test_recordFailureCapturesReason() async {
        let m = ConnectionMetrics(flushOnCount: 1)
        let token = await m.begin(type: .relayWorker, role: .initiator)
        await m.recordFailure(token, reason: "timeout")
        let last = await m.lastFlushedMetric
        if case .failure(let reason) = last?.outcome {
            XCTAssertEqual(reason, "timeout")
        } else {
            XCTFail("expected .failure")
        }
    }

    func test_iceGatherOrderRecordsFirstOccurrencePerType() async {
        let m = ConnectionMetrics(flushOnCount: 1)
        let token = await m.begin(type: .relayWorker, role: .joiner)
        await m.recordICEGather(token, candidate: .host, order: 1, isIPv6: false)
        await m.recordICEGather(token, candidate: .srflx, order: 2, isIPv6: false)
        await m.recordICEGather(token, candidate: .srflx, order: 3, isIPv6: false) // dup — keep first
        await m.recordICEGather(token, candidate: .relay, order: 4, isIPv6: true)
        await m.recordConnected(token, used: .relay, ipv6Connected: true)
        let last = await m.lastFlushedMetric
        XCTAssertEqual(last?.iceStats?.srflxGatherOrder, 2)
        XCTAssertEqual(last?.iceStats?.relayGatherOrder, 4)
        XCTAssertEqual(last?.iceStats?.ipv6CandidateGathered, true)
        XCTAssertEqual(last?.iceStats?.ipv6Connected, true)
        XCTAssertEqual(last?.iceStats?.candidatesGathered, [.host, .srflx, .srflx, .relay])
        XCTAssertEqual(last?.iceStats?.candidatesUsed, .relay)
    }

    func test_disabledConfig_dropsMetric() async {
        let m = ConnectionMetrics(flushOnCount: 1)
        await m.updateRemoteConfig(.init(sampleRate: 1.0, enabled: false))
        let token = await m.begin(type: .localBonjour, role: .initiator)
        await m.recordConnected(token, used: .host)
        let flushedCount = await m.lastFlushedCount
        let last = await m.lastFlushedMetric
        XCTAssertEqual(flushedCount, 0)
        XCTAssertNil(last)
    }

    func test_zeroSampleRate_dropsMetric() async {
        let m = ConnectionMetrics(flushOnCount: 1)
        await m.updateRemoteConfig(.init(sampleRate: 0.0, enabled: true))
        let token = await m.begin(type: .localBonjour, role: .initiator)
        await m.recordConnected(token, used: .host)
        let flushedCount = await m.lastFlushedCount
        XCTAssertEqual(flushedCount, 0)
    }
}
