import XCTest
import Network
@testable import PeerDrop

/// Integration tests that verify end-to-end message framing over a real
/// NWListener + NWConnection loopback on localhost.
final class LoopbackIntegrationTests: XCTestCase {

    private var listener: NWListener!
    private var listenerPort: UInt16!
    private var serverConnection: NWConnection?

    override func setUp() async throws {
        try await super.setUp()

        let params = NWParameters.peerDrop()
        listener = try NWListener(using: params, on: .any)

        // Set handler BEFORE starting (required by Network.framework)
        listener.newConnectionHandler = { [weak self] conn in
            self?.serverConnection = conn
            conn.start(queue: .global(qos: .userInitiated))
        }

        let started = expectation(description: "listener ready")
        listener.stateUpdateHandler = { state in
            if case .ready = state { started.fulfill() }
        }
        listener.start(queue: .global(qos: .userInitiated))

        await fulfillment(of: [started], timeout: 10)
        listenerPort = listener.port?.rawValue
        XCTAssertNotNil(listenerPort, "Listener did not bind to a port")
    }

    override func tearDown() async throws {
        serverConnection?.cancel()
        serverConnection = nil
        listener?.cancel()
        listener = nil
        try await super.tearDown()
    }

    private func makeClient() -> NWConnection {
        let params = NWParameters.peerDrop()
        return NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: listenerPort)!,
            using: params
        )
    }

    // MARK: - Tests

    /// Verify a single PeerMessage round-trips through the framer over loopback TCP.
    func testSingleMessageRoundTrip() async throws {
        let received = expectation(description: "message received")

        let client = makeClient()
        client.start(queue: .global(qos: .userInitiated))
        try await client.waitReady()

        // Wait briefly for server to accept
        try await Task.sleep(nanoseconds: 200_000_000)
        guard let server = serverConnection else {
            XCTFail("No server connection accepted")
            return
        }

        Task {
            let msg = try await server.receiveMessage()
            XCTAssertEqual(msg.type, .hello)
            XCTAssertEqual(msg.senderID, "test-peer")
            received.fulfill()
        }

        let hello = PeerMessage(type: .hello, senderID: "test-peer")
        try await client.sendMessage(hello)

        await fulfillment(of: [received], timeout: 5)
        client.cancel()
    }

    /// Verify multiple sequential messages arrive in order.
    func testMultipleMessagesInOrder() async throws {
        let allReceived = expectation(description: "all messages received")
        var receivedTypes: [MessageType] = []

        let client = makeClient()
        client.start(queue: .global(qos: .userInitiated))
        try await client.waitReady()

        try await Task.sleep(nanoseconds: 200_000_000)
        guard let server = serverConnection else {
            XCTFail("No server connection accepted")
            return
        }

        Task {
            for _ in 0..<3 {
                let msg = try await server.receiveMessage()
                receivedTypes.append(msg.type)
            }
            allReceived.fulfill()
        }

        try await client.sendMessage(PeerMessage(type: .hello, senderID: "p"))
        try await client.sendMessage(PeerMessage.connectionRequest(senderID: "p"))
        try await client.sendMessage(PeerMessage.disconnect(senderID: "p"))

        await fulfillment(of: [allReceived], timeout: 5)
        XCTAssertEqual(receivedTypes, [.hello, .connectionRequest, .disconnect])
        client.cancel()
    }

    /// Verify a message with a large payload (simulating a file chunk).
    func testLargePayloadRoundTrip() async throws {
        let received = expectation(description: "large message received")
        let chunkData = Data(repeating: 0xAB, count: 64 * 1024) // 64 KB

        let client = makeClient()
        client.start(queue: .global(qos: .userInitiated))
        try await client.waitReady()

        try await Task.sleep(nanoseconds: 200_000_000)
        guard let server = serverConnection else {
            XCTFail("No server connection accepted")
            return
        }

        Task {
            let msg = try await server.receiveMessage()
            XCTAssertEqual(msg.type, .fileChunk)
            XCTAssertEqual(msg.payload?.count, 64 * 1024)
            received.fulfill()
        }

        let chunk = PeerMessage.fileChunk(chunkData, senderID: "sender")
        try await client.sendMessage(chunk)

        await fulfillment(of: [received], timeout: 10)
        client.cancel()
    }

    /// Verify bidirectional communication (server replies to client).
    func testBidirectionalExchange() async throws {
        let client = makeClient()
        client.start(queue: .global(qos: .userInitiated))
        try await client.waitReady()

        try await Task.sleep(nanoseconds: 200_000_000)
        guard let server = serverConnection else {
            XCTFail("No server connection accepted")
            return
        }

        // Server receives and replies
        Task {
            let msg = try await server.receiveMessage()
            XCTAssertEqual(msg.type, .connectionRequest)
            let accept = PeerMessage.connectionAccept(senderID: "server")
            try await server.sendMessage(accept)
        }

        try await client.sendMessage(PeerMessage.connectionRequest(senderID: "client"))

        let reply = try await client.receiveMessage()
        XCTAssertEqual(reply.type, .connectionAccept)
        XCTAssertEqual(reply.senderID, "server")
        client.cancel()
    }
}
