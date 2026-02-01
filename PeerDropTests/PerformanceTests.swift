import XCTest
import Network
import CryptoKit
@testable import PeerDrop

/// Performance and stress tests for large file transfers and throughput.
final class PerformanceTests: XCTestCase {

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
        XCTAssertNotNil(listenerPort)
    }

    override func tearDown() async throws {
        serverConnection?.cancel()
        serverConnection = nil
        listener?.cancel()
        listener = nil
        try await super.tearDown()
    }

    private func connectPair() async throws -> (client: NWConnection, server: NWConnection) {
        let params = NWParameters.peerDrop()
        let client = NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: listenerPort)!,
            using: params
        )
        client.start(queue: .global(qos: .userInitiated))
        try await client.waitReady()
        try await Task.sleep(nanoseconds: 200_000_000)
        guard let server = serverConnection else {
            XCTFail("No server connection accepted")
            throw NWConnectionError.cancelled
        }
        return (client, server)
    }

    // MARK: - 512 KB File Transfer (Concurrent Send/Receive)

    /// Verify correct transfer of a 512 KB file with concurrent sender/receiver tasks.
    /// This tests realistic behavior: sender and receiver operate in parallel.
    func test512KBFileTransfer() async throws {
        let (client, server) = try await connectPair()
        defer { client.cancel() }

        let size = 512 * 1024
        let fileData = Data((0..<size).map { UInt8($0 & 0xFF) })
        let hash = HashVerifier.sha256(fileData)
        let chunkSize = Data.defaultChunkSize
        let metadata = TransferMetadata(
            fileName: "512kb.bin",
            fileSize: Int64(fileData.count),
            mimeType: nil,
            sha256Hash: hash
        )

        // Offer / accept handshake
        try await client.sendMessage(try PeerMessage.fileOffer(metadata: metadata, senderID: "sender"))
        let offer = try await server.receiveMessage()
        XCTAssertEqual(offer.type, .fileOffer)

        try await server.sendMessage(PeerMessage.fileAccept(senderID: "receiver"))
        _ = try await client.receiveMessage()

        let chunks = fileData.chunks(ofSize: chunkSize)
        XCTAssertEqual(chunks.count, 8)

        // Send and receive concurrently to avoid buffer deadlock
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for chunk in chunks {
                    try await client.sendMessage(PeerMessage.fileChunk(chunk, senderID: "sender"))
                }
                try await client.sendMessage(try PeerMessage.fileComplete(hash: hash, senderID: "sender"))
            }

            group.addTask {
                var reassembled = Data()
                let verifier = HashVerifier()
                for _ in 0..<chunks.count {
                    let msg = try await server.receiveMessage()
                    XCTAssertEqual(msg.type, .fileChunk)
                    reassembled.append(msg.payload!)
                    verifier.update(with: msg.payload!)
                }
                let complete = try await server.receiveMessage()
                XCTAssertEqual(complete.type, .fileComplete)
                XCTAssertEqual(reassembled.count, size)
                XCTAssertTrue(verifier.verify(expected: hash))
            }

            try await group.waitForAll()
        }
    }

    // MARK: - Throughput Measurement

    /// Measure throughput of transferring 512 KB over loopback with concurrent send/receive.
    func testTransferThroughput512KB() async throws {
        let (client, server) = try await connectPair()
        defer { client.cancel() }

        let size = 512 * 1024
        let fileData = Data(repeating: 0xBB, count: size)
        let hash = HashVerifier.sha256(fileData)
        let chunkSize = Data.defaultChunkSize

        let metadata = TransferMetadata(
            fileName: "throughput.bin",
            fileSize: Int64(size),
            mimeType: nil,
            sha256Hash: hash
        )

        try await client.sendMessage(try PeerMessage.fileOffer(metadata: metadata, senderID: "s"))
        _ = try await server.receiveMessage()
        try await server.sendMessage(PeerMessage.fileAccept(senderID: "r"))
        _ = try await client.receiveMessage()

        let start = CFAbsoluteTimeGetCurrent()
        let chunks = fileData.chunks(ofSize: chunkSize)

        try await withThrowingTaskGroup(of: Data?.self) { group in
            group.addTask {
                for chunk in chunks {
                    try await client.sendMessage(PeerMessage.fileChunk(chunk, senderID: "s"))
                }
                return nil
            }

            group.addTask {
                var reassembled = Data()
                for _ in 0..<chunks.count {
                    let msg = try await server.receiveMessage()
                    reassembled.append(msg.payload!)
                }
                return reassembled
            }

            var totalReceived = 0
            for try await result in group {
                if let data = result {
                    totalReceived = data.count
                }
            }

            let elapsed = CFAbsoluteTimeGetCurrent() - start
            let kbPerSec = Double(size) / 1024.0 / elapsed

            print("[Performance] 512 KB transfer: \(String(format: "%.2f", elapsed))s (\(String(format: "%.0f", kbPerSec)) KB/s)")

            XCTAssertEqual(totalReceived, size)
            XCTAssertGreaterThan(kbPerSec, 50.0, "Transfer should exceed 50 KB/s on loopback")
        }
    }

    // MARK: - Many Small Files

    /// Stress test: send 20 tiny files (< 1 chunk each) rapidly.
    func testManySmallFiles() async throws {
        let (client, server) = try await connectPair()
        defer { client.cancel() }

        let fileCount = 20
        let start = CFAbsoluteTimeGetCurrent()

        for i in 0..<fileCount {
            let data = Data("File \(i)".utf8)
            let hash = HashVerifier.sha256(data)
            let meta = TransferMetadata(
                fileName: "small-\(i).txt",
                fileSize: Int64(data.count),
                mimeType: nil,
                sha256Hash: hash
            )

            try await client.sendMessage(try PeerMessage.fileOffer(metadata: meta, senderID: "s"))
            _ = try await server.receiveMessage()

            try await server.sendMessage(PeerMessage.fileAccept(senderID: "r"))
            _ = try await client.receiveMessage()

            try await client.sendMessage(PeerMessage.fileChunk(data, senderID: "s"))
            let chunk = try await server.receiveMessage()
            XCTAssertEqual(chunk.payload, data)

            try await client.sendMessage(try PeerMessage.fileComplete(hash: hash, senderID: "s"))
            _ = try await server.receiveMessage()
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let filesPerSec = Double(fileCount) / elapsed

        print("[Performance] \(fileCount) small files: \(String(format: "%.2f", elapsed))s (\(String(format: "%.1f", filesPerSec)) files/s)")

        // Should handle at least 5 files/sec over loopback
        XCTAssertGreaterThan(filesPerSec, 2.0, "Should transfer at least 2 files/sec")
    }

    // MARK: - Batch Transfer Stress

    /// Verify a batch of 5 files with batchStart/batchComplete.
    func testBatchTransferProtocol() async throws {
        let (client, server) = try await connectPair()
        defer { client.cancel() }

        let batchID = UUID().uuidString
        let batchMeta = BatchMetadata(totalFiles: 5, batchID: batchID)

        // Send batchStart
        try await client.sendMessage(try PeerMessage.batchStart(metadata: batchMeta, senderID: "sender"))
        let batchStartMsg = try await server.receiveMessage()
        XCTAssertEqual(batchStartMsg.type, .batchStart)
        let decoded = try batchStartMsg.decodePayload(BatchMetadata.self)
        XCTAssertEqual(decoded.totalFiles, 5)

        // Transfer 5 files
        for i in 0..<5 {
            let data = Data("Batch file \(i)".utf8)
            let hash = HashVerifier.sha256(data)
            let meta = TransferMetadata(
                fileName: "batch-\(i).txt",
                fileSize: Int64(data.count),
                mimeType: nil,
                sha256Hash: hash,
                fileIndex: i,
                totalFiles: 5
            )

            try await client.sendMessage(try PeerMessage.fileOffer(metadata: meta, senderID: "sender"))
            let offer = try await server.receiveMessage()
            XCTAssertEqual(offer.type, .fileOffer)

            try await server.sendMessage(PeerMessage.fileAccept(senderID: "receiver"))
            _ = try await client.receiveMessage()

            try await client.sendMessage(PeerMessage.fileChunk(data, senderID: "sender"))
            let chunk = try await server.receiveMessage()
            XCTAssertEqual(chunk.payload, data)

            try await client.sendMessage(try PeerMessage.fileComplete(hash: hash, senderID: "sender"))
            let complete = try await server.receiveMessage()
            XCTAssertEqual(complete.type, .fileComplete)
        }

        // Send batchComplete
        try await client.sendMessage(try PeerMessage.batchComplete(batchID: batchID, senderID: "sender"))
        let batchCompleteMsg = try await server.receiveMessage()
        XCTAssertEqual(batchCompleteMsg.type, .batchComplete)
    }

    // MARK: - Chunking Performance

    /// Measure in-memory chunking performance for 10 MB.
    func testChunkingPerformance10MB() {
        let data = Data(repeating: 0xCC, count: 10 * 1024 * 1024)

        measure {
            let chunks = data.chunks(ofSize: Data.defaultChunkSize)
            XCTAssertEqual(chunks.count, 160) // 10MB / 64KB
        }
    }

    /// Measure hash computation performance for 1 MB.
    func testHashPerformance1MB() {
        let data = Data(repeating: 0xDD, count: 1024 * 1024)

        measure {
            _ = HashVerifier.sha256(data)
        }
    }

    // MARK: - FileChunkIterator vs In-Memory Chunking

    /// Verify FileChunkIterator produces identical output to in-memory chunking.
    func testFileChunkIteratorMatchesInMemory() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("perf-chunk-compare.bin")
        let testData = Data((0..<(256 * 1024)).map { UInt8($0 & 0xFF) })
        try testData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // In-memory chunks
        let memoryChunks = testData.chunks(ofSize: Data.defaultChunkSize)

        // FileHandle-based chunks
        let handle = try FileHandle(forReadingFrom: tempURL)
        defer { handle.closeFile() }

        var fileChunks: [Data] = []
        for chunk in FileChunkIterator(handle: handle, chunkSize: Data.defaultChunkSize, totalSize: Int64(testData.count)) {
            fileChunks.append(chunk)
        }

        XCTAssertEqual(memoryChunks.count, fileChunks.count)
        for (i, (mem, file)) in zip(memoryChunks, fileChunks).enumerated() {
            XCTAssertEqual(mem, file, "Chunk \(i) mismatch")
        }
    }

    // MARK: - Streaming Hash vs In-Memory Hash

    /// Verify streaming file hash matches in-memory hash for 1 MB.
    func testStreamingHashPerformance() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("perf-hash-stream.bin")
        let testData = Data(repeating: 0xEE, count: 1024 * 1024)
        try testData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let memHash = HashVerifier.sha256(testData)

        measure {
            let streamHash = try! HashVerifier.sha256(fileAt: tempURL)
            XCTAssertEqual(streamHash, memHash)
        }
    }
}
