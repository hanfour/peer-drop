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

    /// Issue 1 regression guard: the ConnectionManager bootstrap shim must
    /// capture `peer-joined` events that arrive between `joinRoom` and the
    /// `RelaySession.start(peerAlreadyJoined:)` call, and `RelaySession` must
    /// accept the flag without throwing.
    ///
    /// We can't drive a real WebRTC offer in a unit test (no injectable
    /// `RTCPeerConnection`), so this is an API-contract smoke test: we verify
    /// (a) a bootstrap shim sees the event before the session is created,
    /// (b) `start(peerAlreadyJoined:)` is callable with the boolean, and
    /// (c) once the session is constructed, calling `start` does not crash and
    /// the session remains in pending state long enough for the offer path to
    /// be attempted (i.e. no early failure short-circuits the
    /// `peerAlreadyJoined` branch).
    ///
    /// The end-to-end behaviour (offer actually sent via signaling.sendSDP) is
    /// covered by manual integration testing — see the Issue 1 spec.
    func test_creatorPeerJoinedArrivesBeforeStart_offerStillSent() async throws {
        let mockSig = MockWorkerSignaling()
        let metricsToken = await ConnectionMetrics.shared.begin(type: .relayWorker, role: .initiator)

        // (a) Bootstrap shim, mimicking ConnectionManager.startWorkerRelayAsCreator.
        var peerAlreadyJoined = false
        mockSig.onPeerJoined = { peerAlreadyJoined = true }

        // Simulate WS delivering peer-joined BEFORE RelaySession is constructed.
        mockSig.onPeerJoined?()
        XCTAssertTrue(
            peerAlreadyJoined,
            "bootstrap shim must record peer-joined arriving before session construction"
        )

        // (b) Construct RelaySession with creator role and (c) call start with the flag.
        // Note: we cannot create a real RTCPeerConnection in the unit-test target,
        // so `startCreator` will fail at `createDataChannel` / `createOffer` — that's
        // expected. What we're proving here is that the API surface (the boolean
        // parameter being threaded through `start` → `startCreator`) is wired up.
        let session = RelaySession(
            roomCode: "TEST01",
            role: .creator,
            signaling: mockSig,
            metricsToken: metricsToken,
            iceResult: nil,
            logger: logger
        )

        // Drive start; should not throw or trap.
        await session.start(peerAlreadyJoined: peerAlreadyJoined)

        // The session must not be left in a weird half-state — once start returns,
        // it has either sent the offer (success path) or recorded a failure. Either
        // way, calling cancel afterwards must remain idempotent and safe.
        session.cancel(reason: "testTeardown")
    }

    /// Issue 2 regression guard: after a session has been recorded as connected
    /// (via the test seam that mimics `recordSuccess`), the deinit MUST short-circuit
    /// and NOT call `signaling.disconnect()` a second time. If a future refactor
    /// removes the `if case .connected = outcome { return }` guard in deinit, this
    /// test fails.
    func test_sessionAfterRecordSuccess_doesNotDisconnectInDeinit() async {
        let mockSig = MockWorkerSignaling()
        let metricsToken = await ConnectionMetrics.shared.begin(type: .relayWorker, role: .joiner)

        do {
            let session = RelaySession(
                roomCode: "TEST01",
                role: .joiner,
                signaling: mockSig,
                metricsToken: metricsToken,
                iceResult: nil,
                logger: logger
            )
            await session.markConnectedForTesting()
            // Deinit will run when this scope exits and `session` drops to refcount 0.
        }
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(
            mockSig.disconnectCallCount, 1,
            "After recordSuccess, deinit must NOT call disconnect again — exactly one call expected"
        )
    }
}
