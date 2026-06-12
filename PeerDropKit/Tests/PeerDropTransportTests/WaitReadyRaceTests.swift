import XCTest
import Network
@testable import PeerDropTransport

/// Regression coverage for the waitReady() lost-wakeup race (2026-06-12):
///
/// `waitReadyInternal()` installs a `stateUpdateHandler` and waits for the
/// NEXT state transition — it never inspects the connection's CURRENT
/// state. NWConnection does not replay the current state to a freshly
/// installed handler, so a connection that reached `.ready` before the
/// handler was attached hangs until the 15s timeout. On loopback (Mac app
/// ↔ iOS simulator on the same host) start→ready completes almost
/// instantly, making the race the COMMON case: the receiver never read
/// HELLO and the initiator always hit "Connection request timed out".
@MainActor
final class WaitReadyRaceTests: XCTestCase {

    func testWaitReadyResolvesWhenConnectionIsAlreadyReady() async throws {
        // Loopback listener that starts (and keeps) every inbound connection.
        let listener = try NWListener(using: .tcp, on: .any)
        var inbound: [NWConnection] = []
        listener.newConnectionHandler = { conn in
            inbound.append(conn)
            conn.start(queue: .global())
        }
        listener.start(queue: .global())
        defer { listener.cancel(); inbound.forEach { $0.cancel() } }

        // Wait for the listener port.
        var port: NWEndpoint.Port?
        for _ in 0..<100 {
            if let p = listener.port, p.rawValue != 0 { port = p; break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let boundPort = try XCTUnwrap(port, "listener never became ready")

        let connection = NWConnection(
            host: "127.0.0.1",
            port: boundPort,
            using: NWParameters.peerDrop()
        )
        connection.start(queue: .global())
        defer { connection.cancel() }

        // Poll until the connection is ALREADY ready — i.e. the state
        // transition happened before waitReady() installs its handler.
        // This reproduces the incoming-connection path where
        // ConnectionManager calls connection.start(...) first and
        // waitReady() afterwards.
        for _ in 0..<200 {
            if connection.state == .ready { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(connection.state, .ready, "loopback connect should become ready quickly")

        // Pre-fix: this throws NWConnectionError.timeout after 2s because
        // the handler never fires again. Post-fix: returns immediately.
        try await connection.waitReady(timeout: 2)
    }
}
