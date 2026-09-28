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
