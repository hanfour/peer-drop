import XCTest
import Network
import CryptoKit
@testable import PeerDrop

/// End-to-end integration tests that verify the full file transfer protocol
/// (offer, accept/reject, chunks, complete with hash verification) over a real
/// NWListener + NWConnection loopback on localhost.
final class FileTransferIntegrationTests: XCTestCase {

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

    /// Helper: connect client and wait for the server to accept.
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

    // MARK: - File Offer

    /// Verify a file offer with TransferMetadata round-trips correctly over TCP.
    func testFileOfferRoundTrip() async throws {
        let (client, server) = try await connectPair()
        defer { client.cancel() }

        let metadata = TransferMetadata(
            fileName: "test-file.txt",
            fileSize: 1024,
            mimeType: "text/plain",
            sha256Hash: "abc123"
        )
        let offer = try PeerMessage.fileOffer(metadata: metadata, senderID: "test-sender")
        try await client.sendMessage(offer)

        let msg = try await server.receiveMessage()
        XCTAssertEqual(msg.type, .fileOffer)
        XCTAssertEqual(msg.senderID, "test-sender")

        let decoded = try msg.decodePayload(TransferMetadata.self)
        XCTAssertEqual(decoded.fileName, "test-file.txt")
        XCTAssertEqual(decoded.fileSize, 1024)
        XCTAssertEqual(decoded.mimeType, "text/plain")
        XCTAssertEqual(decoded.sha256Hash, "abc123")
    }

    // MARK: - File Reject

    /// Verify the file reject flow: offer then reject.
    func testFileRejectFlow() async throws {
        let (client, server) = try await connectPair()
        defer { client.cancel() }

        let metadata = TransferMetadata(
            fileName: "unwanted.zip",
            fileSize: 1_000_000,
            mimeType: "application/zip",
            sha256Hash: "deadbeef"
        )

        try await client.sendMessage(try PeerMessage.fileOffer(metadata: metadata, senderID: "sender"))
        let receivedOffer = try await server.receiveMessage()
        XCTAssertEqual(receivedOffer.type, .fileOffer)

        try await server.sendMessage(PeerMessage.fileReject(senderID: "receiver"))
        let receivedReject = try await client.receiveMessage()
        XCTAssertEqual(receivedReject.type, .fileReject)
        XCTAssertEqual(receivedReject.senderID, "receiver")
    }

    // MARK: - Single-Chunk Transfer

    /// Verify a complete single-chunk file transfer: offer, accept, chunk, complete with hash.
    func testSmallFileTransferEndToEnd() async throws {
        let (client, server) = try await connectPair()
        defer { client.cancel() }

        let fileData = Data("Hello, PeerDrop!".utf8)
        let hash = HashVerifier.sha256(fileData)
        let metadata = TransferMetadata(
            fileName: "hello.txt",
            fileSize: Int64(fileData.count),
            mimeType: "text/plain",
            sha256Hash: hash
        )

        // Offer
        try await client.sendMessage(try PeerMessage.fileOffer(metadata: metadata, senderID: "sender"))
        let receivedOffer = try await server.receiveMessage()
        XCTAssertEqual(receivedOffer.type, .fileOffer)
        let receivedMeta = try receivedOffer.decodePayload(TransferMetadata.self)
        XCTAssertEqual(receivedMeta.fileName, "hello.txt")
        XCTAssertEqual(receivedMeta.fileSize, Int64(fileData.count))
        XCTAssertEqual(receivedMeta.sha256Hash, hash)

        // Accept
        try await server.sendMessage(PeerMessage.fileAccept(senderID: "receiver"))
        let receivedAccept = try await client.receiveMessage()
        XCTAssertEqual(receivedAccept.type, .fileAccept)

        // Chunk
        try await client.sendMessage(PeerMessage.fileChunk(fileData, senderID: "sender"))
        let receivedChunk = try await server.receiveMessage()
        XCTAssertEqual(receivedChunk.type, .fileChunk)
        XCTAssertEqual(receivedChunk.payload, fileData)

        // Complete
        try await client.sendMessage(try PeerMessage.fileComplete(hash: hash, senderID: "sender"))
        let receivedComplete = try await server.receiveMessage()
        XCTAssertEqual(receivedComplete.type, .fileComplete)

        // Hash verification
        let verifier = HashVerifier()
        verifier.update(with: receivedChunk.payload!)
        XCTAssertTrue(verifier.verify(expected: receivedMeta.sha256Hash))
    }

    // MARK: - Multi-Chunk Transfer

    /// Verify multi-chunk transfer with incremental hash verification and reassembly.
    func testMultiChunkFileTransfer() async throws {
        let (client, server) = try await connectPair()
        defer { client.cancel() }

        let chunk1 = Data(repeating: 0x01, count: 100)
        let chunk2 = Data(repeating: 0x02, count: 100)
        let chunk3 = Data(repeating: 0x03, count: 100)
        var expectedData = Data()
        expectedData.append(chunk1)
        expectedData.append(chunk2)
        expectedData.append(chunk3)
        let hash = HashVerifier.sha256(expectedData)

        let metadata = TransferMetadata(
            fileName: "chunks.dat",
            fileSize: 300,
            mimeType: "application/octet-stream",
            sha256Hash: hash
        )

        // Offer
        try await client.sendMessage(try PeerMessage.fileOffer(metadata: metadata, senderID: "sender"))
        let offer = try await server.receiveMessage()
        XCTAssertEqual(offer.type, .fileOffer)

        // Accept
        try await server.sendMessage(PeerMessage.fileAccept(senderID: "receiver"))
        let accept = try await client.receiveMessage()
        XCTAssertEqual(accept.type, .fileAccept)

        // Send 3 chunks
        try await client.sendMessage(PeerMessage.fileChunk(chunk1, senderID: "sender"))
        try await client.sendMessage(PeerMessage.fileChunk(chunk2, senderID: "sender"))
        try await client.sendMessage(PeerMessage.fileChunk(chunk3, senderID: "sender"))

        // Receive and reassemble
        var reassembled = Data()
        let verifier = HashVerifier()
        for i in 0..<3 {
            let msg = try await server.receiveMessage()
            XCTAssertEqual(msg.type, .fileChunk, "Message \(i) should be fileChunk")
            reassembled.append(msg.payload!)
            verifier.update(with: msg.payload!)
        }

        XCTAssertEqual(reassembled.count, 300)
        XCTAssertEqual(reassembled, expectedData)

        // Complete
        try await client.sendMessage(try PeerMessage.fileComplete(hash: hash, senderID: "sender"))
        let complete = try await server.receiveMessage()
        XCTAssertEqual(complete.type, .fileComplete)

        XCTAssertTrue(verifier.verify(expected: hash))
    }

    // MARK: - Hash Verification

    /// Verify incremental HashVerifier produces correct hash over the wire.
    func testHashVerificationEndToEnd() async throws {
        let (client, server) = try await connectPair()
        defer { client.cancel() }

        let testData = Data("Hello, PeerDrop! This is a file transfer test.".utf8)
        let expectedHash = HashVerifier.sha256(testData)

        let metadata = TransferMetadata(
            fileName: "hash-test.txt",
            fileSize: Int64(testData.count),
            mimeType: "text/plain",
            sha256Hash: expectedHash
        )

        // Offer
        try await client.sendMessage(try PeerMessage.fileOffer(metadata: metadata, senderID: "sender"))
        let offer = try await server.receiveMessage()
        let meta = try offer.decodePayload(TransferMetadata.self)
        XCTAssertEqual(meta.sha256Hash, expectedHash)

        // Accept
        try await server.sendMessage(PeerMessage.fileAccept(senderID: "receiver"))
        _ = try await client.receiveMessage()

        // Chunk
        try await client.sendMessage(PeerMessage.fileChunk(testData, senderID: "sender"))
        let chunkMsg = try await server.receiveMessage()

        // Complete
        try await client.sendMessage(try PeerMessage.fileComplete(hash: expectedHash, senderID: "sender"))
        let complete = try await server.receiveMessage()
        XCTAssertEqual(complete.type, .fileComplete)
        let hashDict = try complete.decodePayload([String: String].self)
        XCTAssertEqual(hashDict["hash"], expectedHash)

        // Verify hash matches
        let hasher = HashVerifier()
        hasher.update(with: chunkMsg.payload!)
        XCTAssertTrue(hasher.verify(expected: expectedHash))
    }

    /// Verify hash mismatch detection when received data is corrupted.
    func testHashMismatchDetection() async throws {
        let (client, server) = try await connectPair()
        defer { client.cancel() }

        let fileData = Data("correct content".utf8)
        let correctHash = HashVerifier.sha256(fileData)
        let metadata = TransferMetadata(
            fileName: "file.txt",
            fileSize: Int64(fileData.count),
            mimeType: "text/plain",
            sha256Hash: correctHash
        )

        // Offer and accept
        try await client.sendMessage(try PeerMessage.fileOffer(metadata: metadata, senderID: "sender"))
        _ = try await server.receiveMessage()
        try await server.sendMessage(PeerMessage.fileAccept(senderID: "receiver"))
        _ = try await client.receiveMessage()

        // Send corrupted data
        let corruptData = Data("wrong content!!!".utf8)
        try await client.sendMessage(PeerMessage.fileChunk(corruptData, senderID: "sender"))
        let receivedChunk = try await server.receiveMessage()

        // Verify hash does NOT match
        let verifier = HashVerifier()
        verifier.update(with: receivedChunk.payload!)
        XCTAssertFalse(verifier.verify(expected: correctHash))
    }

    // MARK: - Large File Transfer

    /// Verify a 256 KB file transfer using default 64 KB chunks with full hash verification.
    func testLargeFileTransfer() async throws {
        let (client, server) = try await connectPair()
        defer { client.cancel() }

        let fileData = Data((0..<(256 * 1024)).map { UInt8($0 & 0xFF) })
        let chunkSize = Data.defaultChunkSize
        let hash = HashVerifier.sha256(fileData)
        let metadata = TransferMetadata(
            fileName: "large.bin",
            fileSize: Int64(fileData.count),
            mimeType: "application/octet-stream",
            sha256Hash: hash
        )

        // Offer and accept
        try await client.sendMessage(try PeerMessage.fileOffer(metadata: metadata, senderID: "sender"))
        let offer = try await server.receiveMessage()
        XCTAssertEqual(offer.type, .fileOffer)

        try await server.sendMessage(PeerMessage.fileAccept(senderID: "receiver"))
        let accept = try await client.receiveMessage()
        XCTAssertEqual(accept.type, .fileAccept)

        // Send chunks
        let chunks = fileData.chunks(ofSize: chunkSize)
        XCTAssertEqual(chunks.count, 4) // 256KB / 64KB

        for chunk in chunks {
            try await client.sendMessage(PeerMessage.fileChunk(chunk, senderID: "sender"))
        }

        // Receive and verify
        var reassembled = Data()
        let verifier = HashVerifier()
        for _ in 0..<chunks.count {
            let msg = try await server.receiveMessage()
            XCTAssertEqual(msg.type, .fileChunk)
            reassembled.append(msg.payload!)
            verifier.update(with: msg.payload!)
        }

        // Complete
        try await client.sendMessage(try PeerMessage.fileComplete(hash: hash, senderID: "sender"))
        let complete = try await server.receiveMessage()
        XCTAssertEqual(complete.type, .fileComplete)

        XCTAssertEqual(reassembled.count, fileData.count)
        XCTAssertEqual(reassembled, fileData)
        XCTAssertTrue(verifier.verify(expected: hash))
    }

    // MARK: - Full Protocol Flow

    /// Verify a full handshake (hello, connectionRequest, connectionAccept) followed by file transfer.
    func testHandshakeThenFileTransfer() async throws {
        let (client, server) = try await connectPair()
        defer { client.cancel() }

        // Handshake
        try await client.sendMessage(PeerMessage(type: .hello, senderID: "alice"))
        let hello = try await server.receiveMessage()
        XCTAssertEqual(hello.type, .hello)

        try await client.sendMessage(PeerMessage.connectionRequest(senderID: "alice"))
        let req = try await server.receiveMessage()
        XCTAssertEqual(req.type, .connectionRequest)

        try await server.sendMessage(PeerMessage.connectionAccept(senderID: "bob"))
        let acceptConn = try await client.receiveMessage()
        XCTAssertEqual(acceptConn.type, .connectionAccept)

        // File transfer
        let fileData = Data("After handshake transfer".utf8)
        let hash = HashVerifier.sha256(fileData)
        let metadata = TransferMetadata(
            fileName: "post-handshake.txt",
            fileSize: Int64(fileData.count),
            mimeType: "text/plain",
            sha256Hash: hash
        )

        try await client.sendMessage(try PeerMessage.fileOffer(metadata: metadata, senderID: "alice"))
        let offer = try await server.receiveMessage()
        XCTAssertEqual(offer.type, .fileOffer)

        try await server.sendMessage(PeerMessage.fileAccept(senderID: "bob"))
        let acceptFile = try await client.receiveMessage()
        XCTAssertEqual(acceptFile.type, .fileAccept)

        try await client.sendMessage(PeerMessage.fileChunk(fileData, senderID: "alice"))
        let chunk = try await server.receiveMessage()
        XCTAssertEqual(chunk.type, .fileChunk)
        XCTAssertEqual(chunk.payload, fileData)

        try await client.sendMessage(try PeerMessage.fileComplete(hash: hash, senderID: "alice"))
        let complete = try await server.receiveMessage()
        XCTAssertEqual(complete.type, .fileComplete)

        let verifier = HashVerifier()
        verifier.update(with: fileData)
        XCTAssertTrue(verifier.verify(expected: hash))
    }

    /// Verify two sequential file transfers reuse the same connection correctly.
    func testSequentialFileTransfers() async throws {
        let (client, server) = try await connectPair()
        defer { client.cancel() }

        for i in 0..<2 {
            let fileData = Data("File number \(i)".utf8)
            let hash = HashVerifier.sha256(fileData)
            let metadata = TransferMetadata(
                fileName: "file\(i).txt",
                fileSize: Int64(fileData.count),
                mimeType: "text/plain",
                sha256Hash: hash
            )

            try await client.sendMessage(try PeerMessage.fileOffer(metadata: metadata, senderID: "sender"))
            let offer = try await server.receiveMessage()
            XCTAssertEqual(offer.type, .fileOffer)
            let meta = try offer.decodePayload(TransferMetadata.self)
            XCTAssertEqual(meta.fileName, "file\(i).txt")

            try await server.sendMessage(PeerMessage.fileAccept(senderID: "receiver"))
            let accept = try await client.receiveMessage()
            XCTAssertEqual(accept.type, .fileAccept)

            try await client.sendMessage(PeerMessage.fileChunk(fileData, senderID: "sender"))
            let chunk = try await server.receiveMessage()
            XCTAssertEqual(chunk.payload, fileData)

            try await client.sendMessage(try PeerMessage.fileComplete(hash: hash, senderID: "sender"))
            let complete = try await server.receiveMessage()
            XCTAssertEqual(complete.type, .fileComplete)

            let verifier = HashVerifier()
            verifier.update(with: fileData)
            XCTAssertTrue(verifier.verify(expected: hash))
        }
    }

    /// Verify bidirectional file transfer: client sends to server, then server sends to client.
    func testBidirectionalFileTransfer() async throws {
        let (client, server) = try await connectPair()
        defer { client.cancel() }

        // Client to Server
        let clientFile = Data("from client".utf8)
        let clientHash = HashVerifier.sha256(clientFile)
        let clientMeta = TransferMetadata(
            fileName: "client.txt",
            fileSize: Int64(clientFile.count),
            mimeType: "text/plain",
            sha256Hash: clientHash
        )

        try await client.sendMessage(try PeerMessage.fileOffer(metadata: clientMeta, senderID: "client"))
        let offer1 = try await server.receiveMessage()
        XCTAssertEqual(offer1.type, .fileOffer)

        try await server.sendMessage(PeerMessage.fileAccept(senderID: "server"))
        _ = try await client.receiveMessage()

        try await client.sendMessage(PeerMessage.fileChunk(clientFile, senderID: "client"))
        let chunk1 = try await server.receiveMessage()
        XCTAssertEqual(chunk1.payload, clientFile)

        try await client.sendMessage(try PeerMessage.fileComplete(hash: clientHash, senderID: "client"))
        _ = try await server.receiveMessage()

        // Server to Client
        let serverFile = Data("from server".utf8)
        let serverHash = HashVerifier.sha256(serverFile)
        let serverMeta = TransferMetadata(
            fileName: "server.txt",
            fileSize: Int64(serverFile.count),
            mimeType: "text/plain",
            sha256Hash: serverHash
        )

        try await server.sendMessage(try PeerMessage.fileOffer(metadata: serverMeta, senderID: "server"))
        let offer2 = try await client.receiveMessage()
        XCTAssertEqual(offer2.type, .fileOffer)

        try await client.sendMessage(PeerMessage.fileAccept(senderID: "client"))
        _ = try await server.receiveMessage()

        try await server.sendMessage(PeerMessage.fileChunk(serverFile, senderID: "server"))
        let chunk2 = try await client.receiveMessage()
        XCTAssertEqual(chunk2.payload, serverFile)

        try await server.sendMessage(try PeerMessage.fileComplete(hash: serverHash, senderID: "server"))
        let complete2 = try await client.receiveMessage()
        XCTAssertEqual(complete2.type, .fileComplete)

        let verifier = HashVerifier()
        verifier.update(with: serverFile)
        XCTAssertTrue(verifier.verify(expected: serverHash))
    }

    /// Verify PeerDropFramer.maxMessageSize constant is configured correctly.
    func testFramerMaxMessageSize() {
        XCTAssertEqual(
            PeerDropFramer.maxMessageSize,
            100 * 1024 * 1024,
            "PeerDropFramer should reject messages larger than 100 MB"
        )
    }
}
