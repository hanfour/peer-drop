import XCTest
import os
@testable import PeerDrop

/// Test seam for `WorkerSignaling`. Records every public side effect that
/// `RelaySession` may produce so we can assert on them deterministically
/// without standing up a real WebSocket.
final class MockWorkerSignaling: WorkerSignalingProtocol {
    var onSDPOffer: ((String) -> Void)?
    var onSDPAnswer: ((String) -> Void)?
    var onICECandidate: ((String, String?, Int32) -> Void)?
    var onPeerJoined: (() -> Void)?
    var onError: ((Error) -> Void)?

    private(set) var disconnectCallCount = 0
    private(set) var sentSDPs: [(sdp: String, type: String)] = []
    private(set) var sentICECandidates: [(sdp: String, sdpMid: String?, sdpMLineIndex: Int32)] = []

    var disconnectCalled: Bool { disconnectCallCount > 0 }

    func sendSDP(_ sdp: String, type: String) {
        sentSDPs.append((sdp, type))
    }

    func sendICECandidate(sdp: String, sdpMid: String?, sdpMLineIndex: Int32) {
        sentICECandidates.append((sdp, sdpMid, sdpMLineIndex))
    }

    func disconnect() {
        disconnectCallCount += 1
    }
}

@MainActor
final class RelaySessionTests: XCTestCase {

    private var logger: Logger { Logger(subsystem: "com.hanfour.peerdrop.tests", category: "RelaySession") }

    /// THE critical regression guard. Any v3.3.0-class bug requires this test to fail.
    /// If a session is dropped without successfully connecting, the deinit MUST
    /// close the signaling WebSocket so the Worker DO does not retain a zombie
    /// socket that fills the room.
    func test_sessionDeinitWithoutConnect_disconnectsSignaling() async {
        let mockSig = MockWorkerSignaling()
        let metricsToken = await ConnectionMetrics.shared.begin(type: .relayWorker, role: .joiner)

        // Scope so deinit fires deterministically when the block exits.
        do {
            let session = RelaySession(
                roomCode: "TEST01",
                role: .joiner,
                signaling: mockSig,
                metricsToken: metricsToken,
                iceResult: nil,
                logger: logger
            )
            // Simulate session ending mid-handshake without success — we never call
            // .start() so the .pending outcome is preserved through deinit.
            _ = session
        }

        // deinit runs synchronously here; no await needed.
        XCTAssertTrue(
            mockSig.disconnectCalled,
            "v3.3.0 regression guard: deinit must close signaling when session never connected"
        )
    }

    /// After explicit `cancel()`, signaling MUST be disconnected.
    func test_sessionCancel_disconnectsSignaling() async {
        let mockSig = MockWorkerSignaling()
        let metricsToken = await ConnectionMetrics.shared.begin(type: .relayWorker, role: .joiner)

        let session = RelaySession(
            roomCode: "TEST01",
            role: .joiner,
            signaling: mockSig,
            metricsToken: metricsToken,
            iceResult: nil,
            logger: logger
        )
        session.cancel()
        XCTAssertTrue(mockSig.disconnectCalled, "cancel() must close signaling")
        XCTAssertGreaterThanOrEqual(mockSig.disconnectCallCount, 1)
    }

    /// `cancel()` is idempotent — calling it twice does not crash and does not
    /// double-fire any side effects beyond the first cancellation.
    func test_sessionCancel_isIdempotent() async {
        let mockSig = MockWorkerSignaling()
        let metricsToken = await ConnectionMetrics.shared.begin(type: .relayWorker, role: .joiner)

        let session = RelaySession(
            roomCode: "TEST01",
            role: .joiner,
            signaling: mockSig,
            metricsToken: metricsToken,
            iceResult: nil,
            logger: logger
        )
        session.cancel()
        let firstCount = mockSig.disconnectCallCount
        session.cancel()
        // Once cancelled, subsequent cancels short-circuit before calling disconnect.
        XCTAssertEqual(mockSig.disconnectCallCount, firstCount, "cancel() should be idempotent")
    }

    /// A session that is constructed but immediately abandoned (without start) must
    /// still disconnect signaling. This is the simplest case of the deinit invariant.
    func test_sessionWithoutStart_disconnectsOnDeinit() async {
        let mockSig = MockWorkerSignaling()
        let metricsToken = await ConnectionMetrics.shared.begin(type: .relayWorker, role: .initiator)

        do {
            _ = RelaySession(
                roomCode: "TEST02",
                role: .creator,
                signaling: mockSig,
                metricsToken: metricsToken,
                iceResult: nil,
                logger: logger
            )
        }
        XCTAssertTrue(mockSig.disconnectCalled)
    }
}
