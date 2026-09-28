import XCTest
import Network
@testable import PeerDropTransport
import PeerDropProtocol

/// `sendMessage` must not wait forever for a completion Network withholds.
/// Measured (2026-09-28): on a connection in `.waiting` (here: connection
/// refused) a send's `.contentProcessed` completion is never called until the
/// connection is cancelled — pre-fix, the `.waiting` test hung until killed.
final class SendMessageBoundTests: XCTestCase {
    private func refusedConnection() async throws -> NWConnection {
        // Bind then close a listener so the port is known-closed.
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { $0.cancel() }
        listener.start(queue: DispatchQueue(label: "test.closed"))
        let bindDeadline = Date().addingTimeInterval(5)
        while (listener.port == nil || listener.port!.rawValue == 0) && Date() < bindDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard listener.port != nil, listener.port!.rawValue != 0 else {
            XCTFail("listener never bound"); throw NWConnectionError.timeout
        }
        let port = listener.port!
        listener.cancel()
        try await Task.sleep(nanoseconds: 100_000_000)

        let conn = NWConnection(host: "127.0.0.1", port: port, using: .peerDrop())
        conn.start(queue: DispatchQueue(label: "test.refused"))
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if case .waiting = conn.state { return conn }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("connection never reached .waiting (state=\(conn.state))")
        return conn
    }

    func test_send_onWaitingConnection_throwsInsteadOfHanging() async throws {
        let conn = try await refusedConnection()
        defer { conn.cancel() }
        let started = Date()
        do {
            try await conn.sendMessage(PeerMessage.ping(senderID: "x"))
            XCTFail("send on a .waiting connection should fail")
        } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "send waited on a withheld completion")
    }

    func test_send_onCancelledConnection_throws() async throws {
        let conn = try await refusedConnection()
        conn.cancel()
        do {
            try await conn.sendMessage(PeerMessage.ping(senderID: "x"))
            XCTFail("send on a cancelled connection should fail")
        } catch {}
    }
}

/// #161 I-B: `.waiting` on a connection that was ready is often transient
/// (path loss, AP switch) and recovers; only a never-ready connection fails
/// fast. A send given up on cancels the connection so no late data leaks.
final class SendStatePolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private let waitingError = NWError.posix(.ENETDOWN)

    func test_waiting_neverReady_failsImmediately() {
        var policy = SendStatePolicy(everReady: false, waitingGrace: 10)
        XCTAssertNotNil(policy.verdict(.waiting(waitingError), now: t0))
    }

    func test_waiting_afterReady_toleratedWithinGrace() {
        var policy = SendStatePolicy(everReady: true, waitingGrace: 10)
        XCTAssertNil(policy.verdict(.waiting(waitingError), now: t0))
        XCTAssertNil(policy.verdict(.waiting(waitingError), now: t0.addingTimeInterval(9.9)))
        XCTAssertNotNil(policy.verdict(.waiting(waitingError), now: t0.addingTimeInterval(10)))
    }

    func test_waiting_clockResetsWhenConnectionRecovers() {
        var policy = SendStatePolicy(everReady: true, waitingGrace: 10)
        XCTAssertNil(policy.verdict(.waiting(waitingError), now: t0))
        XCTAssertNil(policy.verdict(.ready, now: t0.addingTimeInterval(8)))
        XCTAssertNil(policy.verdict(.waiting(waitingError), now: t0.addingTimeInterval(9)))
        XCTAssertNil(policy.verdict(.waiting(waitingError), now: t0.addingTimeInterval(18)))
        XCTAssertNotNil(policy.verdict(.waiting(waitingError), now: t0.addingTimeInterval(19)))
    }

    /// #161 review: `.preparing` is not recovery. A connection cycling
    /// `.waiting → .preparing → .waiting` must not restart the grace clock,
    /// or a send could stay outstanding forever.
    func test_waiting_preparingCycle_doesNotResetGrace() {
        var policy = SendStatePolicy(everReady: true, waitingGrace: 10)
        XCTAssertNil(policy.verdict(.waiting(waitingError), now: t0))
        XCTAssertNil(policy.verdict(.preparing, now: t0.addingTimeInterval(8)))
        XCTAssertNil(policy.verdict(.waiting(waitingError), now: t0.addingTimeInterval(9)))
        XCTAssertNotNil(policy.verdict(.waiting(waitingError), now: t0.addingTimeInterval(10)))
    }

    func test_notReady_isCappedOverall() {
        var policy = SendStatePolicy(everReady: true, waitingGrace: 10, notReadyCap: 30)
        XCTAssertNil(policy.verdict(.preparing, now: t0))
        XCTAssertNil(policy.verdict(.preparing, now: t0.addingTimeInterval(29.9)))
        XCTAssertNotNil(policy.verdict(.preparing, now: t0.addingTimeInterval(30)))
    }

    func test_notReadyCap_resetsOnReady() {
        var policy = SendStatePolicy(everReady: true, waitingGrace: 10, notReadyCap: 30)
        XCTAssertNil(policy.verdict(.preparing, now: t0))
        XCTAssertNil(policy.verdict(.ready, now: t0.addingTimeInterval(20)))
        XCTAssertNil(policy.verdict(.preparing, now: t0.addingTimeInterval(21)))
        XCTAssertNil(policy.verdict(.preparing, now: t0.addingTimeInterval(50)))
        XCTAssertNotNil(policy.verdict(.preparing, now: t0.addingTimeInterval(51)))
    }

    func test_readySeen_marksEverReady() {
        var policy = SendStatePolicy(everReady: false, waitingGrace: 10)
        XCTAssertNil(policy.verdict(.ready, now: t0))
        XCTAssertNil(policy.verdict(.waiting(waitingError), now: t0.addingTimeInterval(1)))
    }

    func test_failedAndCancelled_areTerminal() {
        var policy = SendStatePolicy(everReady: true, waitingGrace: 10)
        XCTAssertNotNil(policy.verdict(.failed(waitingError), now: t0))
        XCTAssertNotNil(policy.verdict(.cancelled, now: t0))
    }
}

/// Drives the real send path with an injected state source: the connection
/// object is never started until the test decides, so Network holds the
/// send's completion exactly like a `.waiting` connection does.
final class SendMessageWaitingRecoveryTests: XCTestCase {
    private final class StateBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: NWConnection.State
        private var gaveUp = false
        init(_ s: NWConnection.State) { value = s }
        var state: NWConnection.State { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ s: NWConnection.State) { lock.lock(); value = s; lock.unlock() }
        var didGiveUp: Bool { lock.lock(); defer { lock.unlock() }; return gaveUp }
        func markGaveUp() { lock.lock(); gaveUp = true; lock.unlock() }
    }

    private var listener: NWListener!

    override func setUp() async throws {
        listener = try NWListener(using: .peerDrop(), on: .any)
        listener.newConnectionHandler = { $0.start(queue: DispatchQueue(label: "test.recovery.in")) }
        listener.start(queue: DispatchQueue(label: "test.recovery.l"))
        let deadline = Date().addingTimeInterval(5)
        while (listener.port == nil || listener.port!.rawValue == 0) && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    override func tearDown() async throws { listener.cancel() }

    private func watch(_ box: StateBox, conn: NWConnection, grace: TimeInterval) -> SendWatch {
        SendWatch(
            state: { box.state },
            everReady: true,
            waitingGrace: grace,
            giveUp: { box.markGaveUp(); conn.cancel() },
            markReady: {}
        )
    }

    func test_readyConnection_brieflyWaiting_thenRecovers_sendCompletes() async throws {
        let conn = NWConnection(host: "127.0.0.1", port: listener.port!, using: .peerDrop())
        defer { conn.cancel() }
        let box = StateBox(.waiting(.posix(.ENETDOWN)))
        let send = Task { try await conn.sendMessage(PeerMessage.ping(senderID: "x"), watch: watch(box, conn: conn, grace: 5)) }

        try await Task.sleep(nanoseconds: 300_000_000) // "path lost" for a while
        box.set(.ready)                                  // path back
        conn.start(queue: DispatchQueue(label: "test.recovery.c"))

        try await send.value
        XCTAssertFalse(box.didGiveUp, "a transient .waiting must not abort the send")
    }

    /// The original hang pattern: the state flips `.waiting ↔ .preparing`
    /// forever. The send must still give up (and cancel the connection).
    func test_waitingPreparingCycle_sendGivesUpAndCancels() async throws {
        let conn = NWConnection(host: "127.0.0.1", port: listener.port!, using: .peerDrop())
        defer { conn.cancel() }
        let box = StateBox(.waiting(.posix(.ENETDOWN)))
        let flipper = Task {
            var waiting = true
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                waiting.toggle()
                box.set(waiting ? .waiting(.posix(.ENETDOWN)) : .preparing)
            }
        }
        defer { flipper.cancel() }
        let send = Task { try await conn.sendMessage(PeerMessage.ping(senderID: "x"), watch: watch(box, conn: conn, grace: 0.3)) }

        let deadline = Date().addingTimeInterval(3)
        while !box.didGiveUp && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(box.didGiveUp, "send stayed outstanding while the connection cycled .waiting/.preparing")
        if !box.didGiveUp {
            // Let the real connection come up so the hung send completes.
            box.set(.ready)
            conn.start(queue: DispatchQueue(label: "test.recovery.unblock"))
        }
        _ = try? await send.value
    }

    func test_notReadyPastCap_sendGivesUpAndCancels() async throws {
        let conn = NWConnection(host: "127.0.0.1", port: listener.port!, using: .peerDrop())
        defer { conn.cancel() }
        let box = StateBox(.preparing)
        var w = watch(box, conn: conn, grace: 10)
        w.notReadyCap = 0.3
        let send = Task { try await conn.sendMessage(PeerMessage.ping(senderID: "x"), watch: w) }
        let deadline = Date().addingTimeInterval(3)
        while !box.didGiveUp && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(box.didGiveUp, "send stayed outstanding past the not-ready cap")
        if !box.didGiveUp {
            // Let the real connection come up so the hung send completes.
            box.set(.ready)
            conn.start(queue: DispatchQueue(label: "test.recovery.unblock"))
        }
        _ = try? await send.value
    }

    func test_readyConnection_waitingPastGrace_failsAndCancels() async throws {
        let conn = NWConnection(host: "127.0.0.1", port: listener.port!, using: .peerDrop())
        defer { conn.cancel() }
        let box = StateBox(.waiting(.posix(.ENETDOWN)))
        let started = Date()
        do {
            try await conn.sendMessage(PeerMessage.ping(senderID: "x"), watch: watch(box, conn: conn, grace: 0.3))
            XCTFail("send should fail once .waiting outlasts the grace period")
        } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertTrue(box.didGiveUp, "a send given up on must cancel the connection")
    }
}
