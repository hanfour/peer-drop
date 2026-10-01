import XCTest
import Network
@testable import PeerDropTransport

/// waitReady() must not clobber the caller's `stateUpdateHandler` and must
/// resolve reliably on fast loopback transitions (#161 follow-up). It polls
/// `state` instead of installing a handler after `start()`: such a handler was
/// measured to miss `.ready` in 8–36 of 600 loopback connections. Sockets here
/// run on serial queues, as waitReady requires.
final class WaitReadyHandlerTests: XCTestCase {
    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ v: T) { value = v }
        func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
        func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&value); lock.unlock() }
    }

    private var listener: NWListener!
    private let inbound = Box<[NWConnection]>([])

    override func setUp() async throws {
        listener = try NWListener(using: .tcp, on: .any)
        let inbound = inbound
        listener.newConnectionHandler = { conn in
            inbound.mutate { $0.append(conn) }
            conn.start(queue: DispatchQueue(label: "test.inbound"))
        }
        let ready = Box(false)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.mutate { $0 = true } } }
        listener.start(queue: DispatchQueue(label: "test.listener"))
        for _ in 0..<250 where !ready.get() { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(ready.get(), "listener never became ready")
    }

    override func tearDown() async throws {
        listener.cancel()
        inbound.get().forEach { $0.cancel() }
    }

    private func makeClient() -> NWConnection {
        NWConnection(host: "127.0.0.1", port: listener.port!, using: .tcp)
    }

    func test_waitReady_keepsCallersHandler() async throws {
        let conn = makeClient()
        let seen = Box<[String]>([])
        conn.stateUpdateHandler = { state in seen.mutate { $0.append("\(state)") } }
        conn.start(queue: DispatchQueue(label: "test.client"))

        try await conn.waitReady(timeout: 5)
        conn.cancel()

        var sawCancelled = false
        for _ in 0..<100 {
            if seen.get().contains("cancelled") { sawCancelled = true; break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(sawCancelled, "caller's stateUpdateHandler was replaced by waitReady: saw \(seen.get())")
    }

    func test_waitReady_callerHandlerStillSeesReady() async throws {
        let conn = makeClient()
        let seen = Box<[String]>([])
        conn.stateUpdateHandler = { state in seen.mutate { $0.append("\(state)") } }
        conn.start(queue: DispatchQueue(label: "test.client"))
        try await conn.waitReady(timeout: 5)
        for _ in 0..<100 where !seen.get().contains("ready") {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(seen.get().contains("ready"), "caller's handler missed .ready: \(seen.get())")
        conn.cancel()
    }

    func test_waitReady_manyFastLoopbackConnections_allResolve() async throws {
        var stuck = 0
        for _ in 0..<60 {
            let conn = makeClient()
            conn.start(queue: DispatchQueue(label: "test.client"))
            do { try await conn.waitReady(timeout: 3) } catch { stuck += 1 }
            conn.cancel()
        }
        XCTAssertEqual(stuck, 0)
    }

    func test_waitReady_throwsWhenCancelled() async throws {
        let conn = makeClient()
        conn.start(queue: DispatchQueue(label: "test.client"))
        conn.cancel()
        do {
            try await conn.waitReady(timeout: 3)
            XCTFail("waitReady should throw for a cancelled connection")
        } catch NWConnectionError.timeout {
            XCTFail("cancelled connection hung until timeout")
        } catch {}
    }
}
