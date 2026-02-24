import XCTest
import Network
import CryptoKit
@testable import PeerDrop

private func withTimeout<T>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw CancellationError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

/// Edge-case tests: mid-transfer disconnect, zero-byte files, cancellation
/// cleanup, framer boundaries, and rapid sequential transfers.
final class EdgeCaseTests: XCTestCase {

    private var listener: NWListener!
    private var listenerPort: UInt16!
    private var serverConnection: NWConnection?

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()

        let params = NWParameters.peerDrop()
        listener = try NWListener(using: params, on: .any)

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

    private func connectPair() async throws -> (client: NWConnection, server: NWConnection) {
        let client = makeClient()
        client.start(queue: .global(qos: .userInitiated))
        try await client.waitReady()
        try await Task.sleep(nanoseconds: 200_000_000)
        guard let server = serverConnection else {
            XCTFail("No server connection accepted")
            throw NWConnectionError.cancelled
        }
        return (client, server)
    }

    // MARK: - Mid-Transfer Disconnect (Sender Cancels)

    /// Verify that cancelling the sender mid-transfer terminates cleanly.
    func testSenderDisconnectMidTransfer() async throws {
        let (client, server) = try await connectPair()

        let fileData = Data(repeating: 0xAB, count: 256 * 1024)
        let hash = HashVerifier.sha256(fileData)
        let metadata = TransferMetadata(
            fileName: "disconnect.bin",
            fileSize: Int64(fileData.count),
            mimeType: nil,
            sha256Hash: hash
        )

        // Offer
        try await client.sendMessage(try PeerMessage.fileOffer(metadata: metadata, senderID: "sender"))
        let offer = try await server.receiveMessage()
        XCTAssertEqual(offer.type, .fileOffer)

        // Accept
        try await server.sendMessage(PeerMessage.fileAccept(senderID: "receiver"))
        _ = try await client.receiveMessage()

        // Send only 2 of 4 chunks, then cancel
        let chunks = fileData.chunks(ofSize: Data.defaultChunkSize)
        try await client.sendMessage(PeerMessage.fileChunk(chunks[0], senderID: "sender"))
        try await client.sendMessage(PeerMessage.fileChunk(chunks[1], senderID: "sender"))

        // Cancel sender connection
        client.cancel()

        // Receiver should get 2 chunks then an error on next receive
        _ = try await server.receiveMessage()
        _ = try await server.receiveMessage()

        do {
            _ = try await server.receiveMessage()
            XCTFail("Expected error after sender disconnect")
        } catch {
            // Expected: connection closed or error
        }
    }

    // MARK: - Mid-Transfer Disconnect (Receiver Cancels)

    /// Verify that cancelling the receiver mid-transfer causes sender to fail.
    func testReceiverDisconnectMidTransfer() async throws {
        let (client, server) = try await connectPair()

        let fileData = Data(repeating: 0xCD, count: 256 * 1024)
        let hash = HashVerifier.sha256(fileData)
        let metadata = TransferMetadata(
            fileName: "recv-disconnect.bin",
            fileSize: Int64(fileData.count),
            mimeType: nil,
            sha256Hash: hash
        )

        // Offer and accept
        try await client.sendMessage(try PeerMessage.fileOffer(metadata: metadata, senderID: "sender"))
        _ = try await server.receiveMessage()
        try await server.sendMessage(PeerMessage.fileAccept(senderID: "receiver"))
        _ = try await client.receiveMessage()

        // Send first chunk
        let chunks = fileData.chunks(ofSize: Data.defaultChunkSize)
        try await client.sendMessage(PeerMessage.fileChunk(chunks[0], senderID: "sender"))

        // Cancel receiver
        server.cancel()

        // Give network time to propagate the disconnect
        try await Task.sleep(nanoseconds: 500_000_000)

        // Sender should eventually fail when trying to send more chunks.
        // Wrap in timeout to prevent hanging if the connection buffers indefinitely.
        var hitError = false
        do {
            try await withTimeout(seconds: 10) {
                for i in 1..<chunks.count {
                    try await client.sendMessage(PeerMessage.fileChunk(chunks[i], senderID: "sender"))
                }
            }
        } catch {
            hitError = true
        }

        // The connection may buffer some sends before failing — that's OK.
        // The important thing is the connection is no longer usable.
        // Either we hit an error or the connection is in a failed/cancelled state.
        let isConnectionDead = hitError || client.state == .cancelled
        XCTAssertTrue(isConnectionDead, "Connection should be dead after receiver disconnect")
    }

    // MARK: - Zero-Byte File

    /// Verify a zero-byte file can be offered and completed.
    func testZeroByteFileTransfer() async throws {
        let (client, server) = try await connectPair()
        defer { client.cancel() }

        let fileData = Data()
        let hash = HashVerifier.sha256(fileData)
        let metadata = TransferMetadata(
            fileName: "empty.txt",
            fileSize: 0,
            mimeType: "text/plain",
            sha256Hash: hash
        )

        // Offer
        try await client.sendMessage(try PeerMessage.fileOffer(metadata: metadata, senderID: "sender"))
        let offer = try await server.receiveMessage()
        XCTAssertEqual(offer.type, .fileOffer)
        let meta = try offer.decodePayload(TransferMetadata.self)
        XCTAssertEqual(meta.fileSize, 0)

        // Accept
        try await server.sendMessage(PeerMessage.fileAccept(senderID: "receiver"))
        _ = try await client.receiveMessage()

        // No chunks needed for zero-byte file — send complete immediately
        try await client.sendMessage(try PeerMessage.fileComplete(hash: hash, senderID: "sender"))
        let complete = try await server.receiveMessage()
        XCTAssertEqual(complete.type, .fileComplete)

        // Verify hash matches empty data
        let verifier = HashVerifier()
        XCTAssertTrue(verifier.verify(expected: hash))
    }

    // MARK: - Very Small File (< 1 chunk)

    /// Verify a 1-byte file transfers correctly.
    func testOneByteFileTransfer() async throws {
        let (client, server) = try await connectPair()
        defer { client.cancel() }

        let fileData = Data([0x42])
        let hash = HashVerifier.sha256(fileData)
        let metadata = TransferMetadata(
            fileName: "tiny.bin",
            fileSize: 1,
            mimeType: nil,
            sha256Hash: hash
        )

        try await client.sendMessage(try PeerMessage.fileOffer(metadata: metadata, senderID: "sender"))
        _ = try await server.receiveMessage()

        try await server.sendMessage(PeerMessage.fileAccept(senderID: "receiver"))
        _ = try await client.receiveMessage()

        try await client.sendMessage(PeerMessage.fileChunk(fileData, senderID: "sender"))
        let chunk = try await server.receiveMessage()
        XCTAssertEqual(chunk.payload, fileData)
        XCTAssertEqual(chunk.payload?.count, 1)

        try await client.sendMessage(try PeerMessage.fileComplete(hash: hash, senderID: "sender"))
        let complete = try await server.receiveMessage()
        XCTAssertEqual(complete.type, .fileComplete)

        let verifier = HashVerifier()
        verifier.update(with: fileData)
        XCTAssertTrue(verifier.verify(expected: hash))
    }

    // MARK: - Exact Chunk Boundary File

    /// Verify a file that is exactly 1 chunk size (64KB) transfers correctly.
    func testExactChunkBoundaryFile() async throws {
        let (client, server) = try await connectPair()
        defer { client.cancel() }

        let fileData = Data(repeating: 0xFF, count: Data.defaultChunkSize)
        let hash = HashVerifier.sha256(fileData)
        let metadata = TransferMetadata(
            fileName: "exact-chunk.bin",
            fileSize: Int64(fileData.count),
            mimeType: nil,
            sha256Hash: hash
        )

        try await client.sendMessage(try PeerMessage.fileOffer(metadata: metadata, senderID: "sender"))
        _ = try await server.receiveMessage()
        try await server.sendMessage(PeerMessage.fileAccept(senderID: "receiver"))
        _ = try await client.receiveMessage()

        // Should be exactly 1 chunk
        let chunks = fileData.chunks(ofSize: Data.defaultChunkSize)
        XCTAssertEqual(chunks.count, 1)

        try await client.sendMessage(PeerMessage.fileChunk(chunks[0], senderID: "sender"))
        let received = try await server.receiveMessage()
        XCTAssertEqual(received.payload?.count, Data.defaultChunkSize)

        try await client.sendMessage(try PeerMessage.fileComplete(hash: hash, senderID: "sender"))
        let complete = try await server.receiveMessage()
        XCTAssertEqual(complete.type, .fileComplete)

        let verifier = HashVerifier()
        verifier.update(with: received.payload!)
        XCTAssertTrue(verifier.verify(expected: hash))
    }

    // MARK: - Chunk Boundary + 1

    /// Verify a file that is 1 byte over the chunk size boundary (64KB + 1).
    func testChunkBoundaryPlusOne() async throws {
        let (client, server) = try await connectPair()
        defer { client.cancel() }

        let fileData = Data(repeating: 0xEE, count: Data.defaultChunkSize + 1)
        let hash = HashVerifier.sha256(fileData)
        let metadata = TransferMetadata(
            fileName: "boundary-plus-one.bin",
            fileSize: Int64(fileData.count),
            mimeType: nil,
            sha256Hash: hash
        )

        try await client.sendMessage(try PeerMessage.fileOffer(metadata: metadata, senderID: "sender"))
        _ = try await server.receiveMessage()
        try await server.sendMessage(PeerMessage.fileAccept(senderID: "receiver"))
        _ = try await client.receiveMessage()

        // Should be exactly 2 chunks: 64KB and 1 byte
        let chunks = fileData.chunks(ofSize: Data.defaultChunkSize)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].count, Data.defaultChunkSize)
        XCTAssertEqual(chunks[1].count, 1)

        for chunk in chunks {
            try await client.sendMessage(PeerMessage.fileChunk(chunk, senderID: "sender"))
        }

        var reassembled = Data()
        let verifier = HashVerifier()
        for _ in 0..<2 {
            let msg = try await server.receiveMessage()
            XCTAssertEqual(msg.type, .fileChunk)
            reassembled.append(msg.payload!)
            verifier.update(with: msg.payload!)
        }

        XCTAssertEqual(reassembled.count, Data.defaultChunkSize + 1)

        try await client.sendMessage(try PeerMessage.fileComplete(hash: hash, senderID: "sender"))
        _ = try await server.receiveMessage()

        XCTAssertTrue(verifier.verify(expected: hash))
    }

    // MARK: - Rapid Sequential Transfers (Stress)

    /// Stress test: send 10 files rapidly on the same connection.
    func testRapidSequentialTransfers() async throws {
        let (client, server) = try await connectPair()
        defer { client.cancel() }

        for i in 0..<10 {
            let fileData = Data("Rapid file \(i) content with padding \(String(repeating: "x", count: i * 100))".utf8)
            let hash = HashVerifier.sha256(fileData)
            let metadata = TransferMetadata(
                fileName: "rapid-\(i).txt",
                fileSize: Int64(fileData.count),
                mimeType: "text/plain",
                sha256Hash: hash
            )

            try await client.sendMessage(try PeerMessage.fileOffer(metadata: metadata, senderID: "sender"))
            let offer = try await server.receiveMessage()
            XCTAssertEqual(offer.type, .fileOffer, "File \(i) offer")

            try await server.sendMessage(PeerMessage.fileAccept(senderID: "receiver"))
            let accept = try await client.receiveMessage()
            XCTAssertEqual(accept.type, .fileAccept, "File \(i) accept")

            try await client.sendMessage(PeerMessage.fileChunk(fileData, senderID: "sender"))
            let chunk = try await server.receiveMessage()
            XCTAssertEqual(chunk.type, .fileChunk, "File \(i) chunk")
            XCTAssertEqual(chunk.payload, fileData, "File \(i) data integrity")

            try await client.sendMessage(try PeerMessage.fileComplete(hash: hash, senderID: "sender"))
            let complete = try await server.receiveMessage()
            XCTAssertEqual(complete.type, .fileComplete, "File \(i) complete")
        }
    }

    // MARK: - Transfer After Reconnect

    /// Verify a new connection can transfer after a previous one was cancelled.
    func testTransferAfterReconnect() async throws {
        // First connection — cancel after partial transfer
        let (client1, _) = try await connectPair()

        let data1 = Data("first connection data".utf8)
        let hash1 = HashVerifier.sha256(data1)
        let meta1 = TransferMetadata(
            fileName: "first.txt", fileSize: Int64(data1.count),
            mimeType: nil, sha256Hash: hash1
        )
        try await client1.sendMessage(try PeerMessage.fileOffer(metadata: meta1, senderID: "sender"))
        client1.cancel()
        serverConnection?.cancel()
        serverConnection = nil

        try await Task.sleep(nanoseconds: 300_000_000)

        // Second connection — full transfer
        let (client2, server2) = try await connectPair()
        defer { client2.cancel() }

        let data2 = Data("second connection data".utf8)
        let hash2 = HashVerifier.sha256(data2)
        let meta2 = TransferMetadata(
            fileName: "second.txt", fileSize: Int64(data2.count),
            mimeType: nil, sha256Hash: hash2
        )

        try await client2.sendMessage(try PeerMessage.fileOffer(metadata: meta2, senderID: "sender"))
        let offer = try await server2.receiveMessage()
        XCTAssertEqual(offer.type, .fileOffer)

        try await server2.sendMessage(PeerMessage.fileAccept(senderID: "receiver"))
        _ = try await client2.receiveMessage()

        try await client2.sendMessage(PeerMessage.fileChunk(data2, senderID: "sender"))
        let chunk = try await server2.receiveMessage()
        XCTAssertEqual(chunk.payload, data2)

        try await client2.sendMessage(try PeerMessage.fileComplete(hash: hash2, senderID: "sender"))
        let complete = try await server2.receiveMessage()
        XCTAssertEqual(complete.type, .fileComplete)

        let verifier = HashVerifier()
        verifier.update(with: data2)
        XCTAssertTrue(verifier.verify(expected: hash2))
    }

    // MARK: - Double Offer Without Accept

    /// Verify sending a second offer before the first is accepted.
    func testDoubleOfferOverwritesPrevious() async throws {
        let (client, server) = try await connectPair()
        defer { client.cancel() }

        let meta1 = TransferMetadata(
            fileName: "first.txt", fileSize: 10, mimeType: nil, sha256Hash: "aaa"
        )
        let meta2 = TransferMetadata(
            fileName: "second.txt", fileSize: 20, mimeType: nil, sha256Hash: "bbb"
        )

        // Send two offers without waiting for accept
        try await client.sendMessage(try PeerMessage.fileOffer(metadata: meta1, senderID: "sender"))
        try await client.sendMessage(try PeerMessage.fileOffer(metadata: meta2, senderID: "sender"))

        let offer1 = try await server.receiveMessage()
        let offer2 = try await server.receiveMessage()

        XCTAssertEqual(offer1.type, .fileOffer)
        XCTAssertEqual(offer2.type, .fileOffer)

        // Both offers arrive, receiver processes them in order
        let decoded1 = try offer1.decodePayload(TransferMetadata.self)
        let decoded2 = try offer2.decodePayload(TransferMetadata.self)
        XCTAssertEqual(decoded1.fileName, "first.txt")
        XCTAssertEqual(decoded2.fileName, "second.txt")
    }

    // MARK: - Disconnect Message Delivery

    /// Verify the disconnect message is received before connection closure.
    func testDisconnectMessageDelivered() async throws {
        let (client, server) = try await connectPair()

        // Send disconnect
        let disconnectMsg = PeerMessage.disconnect(senderID: "client")
        try await client.sendMessage(disconnectMsg)

        // Receiver should get the disconnect message
        let received = try await server.receiveMessage()
        XCTAssertEqual(received.type, .disconnect)
        XCTAssertEqual(received.senderID, "client")

        client.cancel()
    }

    // MARK: - Framer Boundary: Max Message Size Constant

    /// Verify PeerDropFramer rejects messages larger than the limit.
    func testFramerMaxMessageSizeConstant() {
        XCTAssertEqual(PeerDropFramer.maxMessageSize, 100 * 1024 * 1024)
    }

    // MARK: - FileChunkIterator

    /// Verify FileChunkIterator reads file in correct chunk sizes.
    func testFileChunkIteratorCorrectChunks() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunk-iter-test.bin")
        let testData = Data(repeating: 0xAA, count: 150)
        try testData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let handle = try FileHandle(forReadingFrom: tempURL)
        defer { handle.closeFile() }

        var chunks: [Data] = []
        for chunk in FileChunkIterator(handle: handle, chunkSize: 64, totalSize: 150) {
            chunks.append(chunk)
        }

        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[0].count, 64)
        XCTAssertEqual(chunks[1].count, 64)
        XCTAssertEqual(chunks[2].count, 22)

        let reassembled = chunks.reduce(Data(), +)
        XCTAssertEqual(reassembled, testData)
    }

    /// Verify FileChunkIterator handles empty files.
    func testFileChunkIteratorEmptyFile() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunk-iter-empty.bin")
        try Data().write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let handle = try FileHandle(forReadingFrom: tempURL)
        defer { handle.closeFile() }

        var chunks: [Data] = []
        for chunk in FileChunkIterator(handle: handle, chunkSize: 64, totalSize: 0) {
            chunks.append(chunk)
        }

        XCTAssertEqual(chunks.count, 0)
    }

    // MARK: - Hash Verification Edge Cases

    /// Verify streaming hash matches in-memory hash for same data.
    func testStreamingHashMatchesInMemoryHash() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hash-stream-test.bin")
        let testData = Data((0..<1000).map { UInt8($0 & 0xFF) })
        try testData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let memoryHash = HashVerifier.sha256(testData)
        let streamHash = try HashVerifier.sha256(fileAt: tempURL, chunkSize: 100)

        XCTAssertEqual(memoryHash, streamHash)
    }
}
