import XCTest
@testable import PeerDrop

/// Tests for the complete media messaging pipeline:
/// Protocol encoding/decoding, ChatManager media persistence, and chunked transfer simulation.
final class MediaMessageTests: XCTestCase {

    // MARK: - MediaMessagePayload Encoding

    func testMediaMessagePayloadRoundTrip() throws {
        let payload = MediaMessagePayload(
            mediaType: .image,
            fileName: "photo.jpg",
            fileSize: 12345,
            mimeType: "image/jpeg",
            duration: nil,
            thumbnailData: Data([0xFF, 0xD8, 0xFF, 0xE0]) // JPEG magic bytes
        )

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(MediaMessagePayload.self, from: data)

        XCTAssertEqual(decoded.mediaType, .image)
        XCTAssertEqual(decoded.fileName, "photo.jpg")
        XCTAssertEqual(decoded.fileSize, 12345)
        XCTAssertEqual(decoded.mimeType, "image/jpeg")
        XCTAssertNil(decoded.duration)
        XCTAssertEqual(decoded.thumbnailData, Data([0xFF, 0xD8, 0xFF, 0xE0]))
        XCTAssertEqual(decoded.id, payload.id)
        XCTAssertEqual(decoded.timestamp.timeIntervalSince1970,
                       payload.timestamp.timeIntervalSince1970, accuracy: 1.0)
    }

    func testVoicePayloadRoundTrip() throws {
        let payload = MediaMessagePayload(
            mediaType: .voice,
            fileName: "voice_12345678.m4a",
            fileSize: 8000,
            mimeType: "audio/m4a",
            duration: 3.5,
            thumbnailData: nil
        )

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(MediaMessagePayload.self, from: data)

        XCTAssertEqual(decoded.mediaType, .voice)
        XCTAssertEqual(decoded.duration, 3.5)
        XCTAssertNil(decoded.thumbnailData)
    }

    func testVideoPayloadRoundTrip() throws {
        let payload = MediaMessagePayload(
            mediaType: .video,
            fileName: "clip.mp4",
            fileSize: 5_000_000,
            mimeType: "video/mp4",
            duration: 15.2,
            thumbnailData: Data(repeating: 0xAA, count: 100)
        )

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(MediaMessagePayload.self, from: data)

        XCTAssertEqual(decoded.mediaType, .video)
        XCTAssertEqual(decoded.duration, 15.2)
        XCTAssertEqual(decoded.fileSize, 5_000_000)
        XCTAssertNotNil(decoded.thumbnailData)
    }

    func testFilePayloadRoundTrip() throws {
        let payload = MediaMessagePayload(
            mediaType: .file,
            fileName: "document.pdf",
            fileSize: 102400,
            mimeType: "application/pdf",
            duration: nil,
            thumbnailData: nil
        )

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(MediaMessagePayload.self, from: data)

        XCTAssertEqual(decoded.mediaType, .file)
        XCTAssertEqual(decoded.fileName, "document.pdf")
        XCTAssertNil(decoded.duration)
        XCTAssertNil(decoded.thumbnailData)
    }

    func testAllMediaTypes() throws {
        let types: [MediaMessagePayload.MediaType] = [.image, .video, .file, .voice]
        for type in types {
            let payload = MediaMessagePayload(
                mediaType: type,
                fileName: "test.\(type.rawValue)",
                fileSize: 100,
                mimeType: "application/octet-stream",
                duration: type == .voice ? 2.0 : nil,
                thumbnailData: nil
            )
            let data = try JSONEncoder().encode(payload)
            let decoded = try JSONDecoder().decode(MediaMessagePayload.self, from: data)
            XCTAssertEqual(decoded.mediaType, type, "Round-trip failed for \(type)")
        }
    }

    // MARK: - PeerMessage with MediaPayload

    func testPeerMessageMediaRoundTrip() throws {
        let payload = MediaMessagePayload(
            mediaType: .image,
            fileName: "photo.jpg",
            fileSize: 5000,
            mimeType: "image/jpeg",
            duration: nil,
            thumbnailData: Data([0x01, 0x02, 0x03])
        )

        let message = try PeerMessage.mediaMessage(payload, senderID: "sender-1")
        let encoded = try message.encoded()
        let decoded = try PeerMessage.decoded(from: encoded)

        XCTAssertEqual(decoded.type, .mediaMessage)
        XCTAssertEqual(decoded.senderID, "sender-1")

        let decodedPayload = try decoded.decodePayload(MediaMessagePayload.self)
        XCTAssertEqual(decodedPayload.fileName, "photo.jpg")
        XCTAssertEqual(decodedPayload.mediaType, .image)
        XCTAssertEqual(decodedPayload.fileSize, 5000)
    }

    func testPeerMessageTextRoundTrip() throws {
        let payload = TextMessagePayload(text: "Hello world")
        let message = try PeerMessage.textMessage(payload, senderID: "sender-2")
        let encoded = try message.encoded()
        let decoded = try PeerMessage.decoded(from: encoded)

        XCTAssertEqual(decoded.type, .textMessage)
        let decodedPayload = try decoded.decodePayload(TextMessagePayload.self)
        XCTAssertEqual(decodedPayload.text, "Hello world")
    }

    // MARK: - Chunked Transfer Simulation

    func testChunkedTransferSimulation() throws {
        // Simulate: sender creates media payload + file chunks, receiver reassembles

        // 1. Sender side: create a "file" (100KB of random data)
        let fileData = Data((0..<100_000).map { _ in UInt8.random(in: 0...255) })

        // 2. Sender encodes metadata
        let metadata = MediaMessagePayload(
            mediaType: .file,
            fileName: "test_transfer.bin",
            fileSize: Int64(fileData.count),
            mimeType: "application/octet-stream",
            duration: nil,
            thumbnailData: nil
        )

        let metaMessage = try PeerMessage.mediaMessage(metadata, senderID: "sender")
        let metaEncoded = try metaMessage.encoded()

        // 3. Sender splits file into chunks (32KB each)
        let chunkSize = 32_768
        var chunks: [Data] = []
        var offset = 0
        while offset < fileData.count {
            let end = min(offset + chunkSize, fileData.count)
            let chunk = fileData[offset..<end]
            let chunkMessage = PeerMessage.fileChunk(Data(chunk), senderID: "sender")
            let chunkEncoded = try chunkMessage.encoded()
            let chunkDecoded = try PeerMessage.decoded(from: chunkEncoded)
            chunks.append(chunkDecoded.payload!)
            offset = end
        }

        // 4. Receiver side: decode metadata
        let metaDecoded = try PeerMessage.decoded(from: metaEncoded)
        XCTAssertEqual(metaDecoded.type, .mediaMessage)
        let receivedMeta = try metaDecoded.decodePayload(MediaMessagePayload.self)
        XCTAssertEqual(receivedMeta.fileName, "test_transfer.bin")
        XCTAssertEqual(receivedMeta.fileSize, Int64(fileData.count))

        // 5. Receiver reassembles chunks
        var reassembled = Data()
        for chunk in chunks {
            reassembled.append(chunk)
        }

        // 6. Verify: reassembled data matches original
        XCTAssertEqual(reassembled.count, fileData.count)
        XCTAssertEqual(reassembled, fileData)

        // 7. Verify chunk count (100KB / 32KB = 4 chunks)
        XCTAssertEqual(chunks.count, 4) // ceil(100000/32768) = 4
    }

    // MARK: - ChatManager Media Persistence

    @MainActor
    func testChatManagerMediaSaveAndLoad() async throws {
        let chatManager = ChatManager()
        let peerID = "test-peer-\(UUID().uuidString.prefix(8))"

        // Save outgoing image message
        let imageMsg = chatManager.saveOutgoingMedia(
            mediaType: .image,
            fileName: "test_photo.jpg",
            fileSize: 12345,
            mimeType: "image/jpeg",
            duration: nil,
            localFileURL: "\(peerID)/abc_test_photo.jpg",
            thumbnailData: Data([0xFF, 0xD8]),
            peerID: peerID,
            peerName: "Test Peer"
        )

        XCTAssertTrue(imageMsg.isMedia)
        XCTAssertEqual(imageMsg.mediaType, "image")
        XCTAssertEqual(imageMsg.fileName, "test_photo.jpg")
        XCTAssertEqual(imageMsg.fileSize, 12345)
        XCTAssertEqual(imageMsg.mimeType, "image/jpeg")
        XCTAssertNil(imageMsg.duration)
        XCTAssertEqual(imageMsg.localFileURL, "\(peerID)/abc_test_photo.jpg")
        XCTAssertEqual(imageMsg.thumbnailData, Data([0xFF, 0xD8]))

        // Save outgoing voice message
        let voiceMsg = chatManager.saveOutgoingMedia(
            mediaType: .voice,
            fileName: "voice_test.m4a",
            fileSize: 8000,
            mimeType: "audio/m4a",
            duration: 3.5,
            localFileURL: "\(peerID)/def_voice_test.m4a",
            thumbnailData: nil,
            peerID: peerID,
            peerName: "Test Peer"
        )

        XCTAssertTrue(voiceMsg.isMedia)
        XCTAssertEqual(voiceMsg.mediaType, "voice")
        XCTAssertEqual(voiceMsg.duration, 3.5)

        // Save incoming media
        let incomingPayload = MediaMessagePayload(
            mediaType: .video,
            fileName: "video_clip.mp4",
            fileSize: 50000,
            mimeType: "video/mp4",
            duration: 10.5,
            thumbnailData: Data(repeating: 0xBB, count: 50)
        )
        let fakeFileData = Data(repeating: 0x00, count: 50000)
        chatManager.saveIncomingMedia(
            payload: incomingPayload,
            fileData: fakeFileData,
            peerID: peerID,
            peerName: "Remote Peer"
        )

        // Reload messages from CoreData
        chatManager.loadMessages(forPeer: peerID)

        // Verify all 3 messages persisted
        XCTAssertEqual(chatManager.messages.count, 3)

        // Check image message
        let loadedImage = chatManager.messages[0]
        XCTAssertEqual(loadedImage.mediaType, "image")
        XCTAssertEqual(loadedImage.fileName, "test_photo.jpg")
        XCTAssertEqual(loadedImage.fileSize, 12345)
        XCTAssertTrue(loadedImage.isOutgoing)

        // Check voice message
        let loadedVoice = chatManager.messages[1]
        XCTAssertEqual(loadedVoice.mediaType, "voice")
        XCTAssertEqual(loadedVoice.duration, 3.5)
        XCTAssertTrue(loadedVoice.isOutgoing)

        // Check incoming video
        let loadedVideo = chatManager.messages[2]
        XCTAssertEqual(loadedVideo.mediaType, "video")
        XCTAssertEqual(loadedVideo.fileName, "video_clip.mp4")
        XCTAssertEqual(loadedVideo.duration, 10.5)
        XCTAssertFalse(loadedVideo.isOutgoing)
        XCTAssertEqual(loadedVideo.peerName, "Remote Peer")

        // Clean up
        chatManager.deleteMessages(forPeer: peerID)
        chatManager.loadMessages(forPeer: peerID)
        XCTAssertEqual(chatManager.messages.count, 0)
    }

    @MainActor
    func testChatManagerMediaFileStorage() async throws {
        let chatManager = ChatManager()
        let peerID = "storage-test-\(UUID().uuidString.prefix(8))"

        // Create test file data
        let testData = "Hello, this is a test file content.".data(using: .utf8)!

        // Save file from data
        let relativePath = chatManager.saveMediaFile(
            data: testData,
            fileName: "test.txt",
            peerID: peerID
        )

        XCTAssertTrue(relativePath.hasPrefix(peerID))
        XCTAssertTrue(relativePath.hasSuffix("test.txt"))

        // Resolve and verify
        let resolvedURL = chatManager.resolveMediaURL(relativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolvedURL.path))

        let readBack = try Data(contentsOf: resolvedURL)
        XCTAssertEqual(readBack, testData)

        // Clean up
        chatManager.deleteMessages(forPeer: peerID)
    }

    @MainActor
    func testChatManagerTextAndMediaMixed() async throws {
        let chatManager = ChatManager()
        let peerID = "mixed-test-\(UUID().uuidString.prefix(8))"

        // Send text
        let textMsg = chatManager.saveOutgoing(
            text: "Check out this photo!",
            peerID: peerID,
            peerName: "Peer"
        )
        XCTAssertFalse(textMsg.isMedia)
        XCTAssertEqual(textMsg.text, "Check out this photo!")

        // Send image
        let imageMsg = chatManager.saveOutgoingMedia(
            mediaType: .image,
            fileName: "photo.jpg",
            fileSize: 5000,
            mimeType: "image/jpeg",
            duration: nil,
            localFileURL: "\(peerID)/photo.jpg",
            thumbnailData: nil,
            peerID: peerID,
            peerName: "Peer"
        )
        XCTAssertTrue(imageMsg.isMedia)

        // Send another text
        let text2 = chatManager.saveOutgoing(
            text: "What do you think?",
            peerID: peerID,
            peerName: "Peer"
        )
        XCTAssertFalse(text2.isMedia)

        // Reload and verify order
        chatManager.loadMessages(forPeer: peerID)
        XCTAssertEqual(chatManager.messages.count, 3)
        XCTAssertFalse(chatManager.messages[0].isMedia) // text
        XCTAssertTrue(chatManager.messages[1].isMedia)   // image
        XCTAssertFalse(chatManager.messages[2].isMedia) // text

        // Clean up
        chatManager.deleteMessages(forPeer: peerID)
    }

    // MARK: - Full Pipeline Integration Tests
    // These simulate the complete send→wire→receive→save flow as it happens in ConnectionManager.

    /// Simulates: Sender encodes image metadata + file chunks → wire → Receiver decodes, reassembles, saves to ChatManager → Verify file data integrity
    @MainActor
    func testFullPipelineImageTransfer() async throws {
        let chatManager = ChatManager()
        let senderID = "img-sender-\(UUID().uuidString.prefix(8))"

        // 1. Create a realistic test image (50KB of pseudo-JPEG data)
        var imageData = Data([0xFF, 0xD8, 0xFF, 0xE0]) // JPEG magic bytes
        imageData.append(Data((0..<50_000).map { _ in UInt8.random(in: 0...255) }))

        // 2. SENDER: Encode metadata PeerMessage (what goes on the wire)
        let metadataPayload = MediaMessagePayload(
            mediaType: .image, fileName: "vacation.jpg",
            fileSize: Int64(imageData.count), mimeType: "image/jpeg",
            duration: nil, thumbnailData: Data([0xFF, 0xD8, 0x00, 0x10])
        )
        let metaMsg = try PeerMessage.mediaMessage(metadataPayload, senderID: senderID)
        let metaWireData = try metaMsg.encoded()

        // 3. SENDER: Split file into 32KB chunks (what goes on the wire)
        let chunkSize = 32_768
        var wireChunks: [Data] = []
        var offset = 0
        while offset < imageData.count {
            let end = min(offset + chunkSize, imageData.count)
            let chunkMsg = PeerMessage.fileChunk(Data(imageData[offset..<end]), senderID: senderID)
            wireChunks.append(try chunkMsg.encoded())
            offset = end
        }

        // 4. RECEIVER: Decode metadata from wire (simulates ConnectionManager.handleMessage)
        let receivedMeta = try PeerMessage.decoded(from: metaWireData)
        XCTAssertEqual(receivedMeta.type, .mediaMessage)
        let receivedPayload = try receivedMeta.decodePayload(MediaMessagePayload.self)
        XCTAssertEqual(receivedPayload.fileName, "vacation.jpg")
        XCTAssertEqual(receivedPayload.fileSize, Int64(imageData.count))

        // 5. RECEIVER: Accumulate chunks (simulates ConnectionManager pending media state)
        var pendingData = Data()
        let expectedSize = receivedPayload.fileSize
        for wireChunk in wireChunks {
            let chunkMsg = try PeerMessage.decoded(from: wireChunk)
            XCTAssertEqual(chunkMsg.type, .fileChunk)
            pendingData.append(chunkMsg.payload!)
        }
        XCTAssertEqual(Int64(pendingData.count), expectedSize)

        // 6. RECEIVER: Finalize (simulates ConnectionManager.finalizeIncomingMedia)
        chatManager.saveIncomingMedia(
            payload: receivedPayload, fileData: pendingData,
            peerID: senderID, peerName: "Alice"
        )

        // 7. VERIFY: Reload and check message
        chatManager.loadMessages(forPeer: senderID)
        XCTAssertEqual(chatManager.messages.count, 1)

        let savedMsg = chatManager.messages[0]
        XCTAssertEqual(savedMsg.mediaType, "image")
        XCTAssertEqual(savedMsg.fileName, "vacation.jpg")
        XCTAssertEqual(savedMsg.fileSize, Int64(imageData.count))
        XCTAssertEqual(savedMsg.mimeType, "image/jpeg")
        XCTAssertFalse(savedMsg.isOutgoing)
        XCTAssertEqual(savedMsg.peerName, "Alice")
        XCTAssertEqual(savedMsg.thumbnailData, Data([0xFF, 0xD8, 0x00, 0x10]))

        // 8. VERIFY: File data integrity — read saved file and compare byte-by-byte
        let resolvedURL = chatManager.resolveMediaURL(savedMsg.localFileURL!)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolvedURL.path), "Media file should exist on disk")
        let savedFileData = try Data(contentsOf: resolvedURL)
        XCTAssertEqual(savedFileData.count, imageData.count, "File size mismatch")
        XCTAssertEqual(savedFileData, pendingData, "Reassembled data should match saved file")
        XCTAssertEqual(savedFileData, imageData, "Saved file should match original image data byte-for-byte")

        // Clean up
        chatManager.deleteMessages(forPeer: senderID)
    }

    /// Full pipeline test for voice message (small file, has duration, no thumbnail)
    @MainActor
    func testFullPipelineVoiceTransfer() async throws {
        let receiverChatManager = ChatManager()
        let senderID = "voice-sender-\(UUID().uuidString.prefix(8))"

        // 1. Create fake M4A voice data (8KB)
        let voiceData = Data((0..<8_000).map { _ in UInt8.random(in: 0...255) })

        // 2. Sender encodes metadata
        let payload = MediaMessagePayload(
            mediaType: .voice, fileName: "voice_msg.m4a",
            fileSize: Int64(voiceData.count), mimeType: "audio/m4a",
            duration: 4.2, thumbnailData: nil
        )
        let metaMsg = try PeerMessage.mediaMessage(payload, senderID: senderID)
        let metaWire = try metaMsg.encoded()

        // 3. Voice is small enough for 1 chunk
        let chunkMsg = PeerMessage.fileChunk(voiceData, senderID: senderID)
        let chunkWire = try chunkMsg.encoded()

        // 4. Receiver decodes
        let recvMeta = try PeerMessage.decoded(from: metaWire)
        let recvPayload = try recvMeta.decodePayload(MediaMessagePayload.self)
        XCTAssertEqual(recvPayload.mediaType, .voice)
        XCTAssertEqual(recvPayload.duration, 4.2)
        XCTAssertNil(recvPayload.thumbnailData)

        let recvChunk = try PeerMessage.decoded(from: chunkWire)
        let reassembled = recvChunk.payload!
        XCTAssertEqual(Int64(reassembled.count), recvPayload.fileSize)

        // 5. Receiver saves
        receiverChatManager.saveIncomingMedia(
            payload: recvPayload, fileData: reassembled,
            peerID: senderID, peerName: "VoiceSender"
        )

        // 6. Verify
        receiverChatManager.loadMessages(forPeer: senderID)
        XCTAssertEqual(receiverChatManager.messages.count, 1)
        let msg = receiverChatManager.messages[0]
        XCTAssertEqual(msg.mediaType, "voice")
        XCTAssertEqual(msg.duration, 4.2)
        XCTAssertEqual(msg.fileSize, Int64(voiceData.count))

        let savedData = try Data(contentsOf: receiverChatManager.resolveMediaURL(msg.localFileURL!))
        XCTAssertEqual(savedData, voiceData, "Voice data should match original byte-for-byte")

        receiverChatManager.deleteMessages(forPeer: senderID)
    }

    /// Full pipeline test for large file (500KB PDF, multiple chunks)
    @MainActor
    func testFullPipelineLargeFileTransfer() async throws {
        let receiverChatManager = ChatManager()
        let senderID = "file-sender-\(UUID().uuidString.prefix(8))"

        // 1. Create 500KB file
        let fileData = Data((0..<500_000).map { _ in UInt8.random(in: 0...255) })

        // 2. Encode metadata
        let payload = MediaMessagePayload(
            mediaType: .file, fileName: "report.pdf",
            fileSize: Int64(fileData.count), mimeType: "application/pdf",
            duration: nil, thumbnailData: nil
        )
        let metaWire = try PeerMessage.mediaMessage(payload, senderID: senderID).encoded()

        // 3. Split into chunks on wire
        let chunkSize = 32_768
        var wireChunks: [Data] = []
        var offset = 0
        while offset < fileData.count {
            let end = min(offset + chunkSize, fileData.count)
            wireChunks.append(try PeerMessage.fileChunk(Data(fileData[offset..<end]), senderID: senderID).encoded())
            offset = end
        }
        XCTAssertEqual(wireChunks.count, 16) // ceil(500000/32768) = 16

        // 4. Receiver decodes metadata
        let recvPayload = try PeerMessage.decoded(from: metaWire).decodePayload(MediaMessagePayload.self)

        // 5. Receiver accumulates all chunks
        var pendingData = Data()
        for wire in wireChunks {
            let msg = try PeerMessage.decoded(from: wire)
            pendingData.append(msg.payload!)
        }
        XCTAssertEqual(Int64(pendingData.count), recvPayload.fileSize)

        // 6. Finalize
        receiverChatManager.saveIncomingMedia(
            payload: recvPayload, fileData: pendingData,
            peerID: senderID, peerName: "FileSender"
        )

        // 7. Verify
        receiverChatManager.loadMessages(forPeer: senderID)
        let msg = receiverChatManager.messages[0]
        XCTAssertEqual(msg.mediaType, "file")
        XCTAssertEqual(msg.fileName, "report.pdf")
        XCTAssertEqual(msg.fileSize, 500_000)

        let savedData = try Data(contentsOf: receiverChatManager.resolveMediaURL(msg.localFileURL!))
        XCTAssertEqual(savedData, fileData, "500KB file should match original byte-for-byte")

        receiverChatManager.deleteMessages(forPeer: senderID)
    }

    /// Full pipeline: video with thumbnail and duration
    @MainActor
    func testFullPipelineVideoTransfer() async throws {
        let receiverChatManager = ChatManager()
        let senderID = "video-sender-\(UUID().uuidString.prefix(8))"

        // 1. Create fake video data (200KB)
        let videoData = Data((0..<200_000).map { _ in UInt8.random(in: 0...255) })
        let thumbnail = Data((0..<2_000).map { _ in UInt8.random(in: 0...255) })

        // 2. Encode and send
        let payload = MediaMessagePayload(
            mediaType: .video, fileName: "clip.mp4",
            fileSize: Int64(videoData.count), mimeType: "video/mp4",
            duration: 12.7, thumbnailData: thumbnail
        )
        let metaWire = try PeerMessage.mediaMessage(payload, senderID: senderID).encoded()

        let chunkSize = 32_768
        var wireChunks: [Data] = []
        var offset = 0
        while offset < videoData.count {
            let end = min(offset + chunkSize, videoData.count)
            wireChunks.append(try PeerMessage.fileChunk(Data(videoData[offset..<end]), senderID: senderID).encoded())
            offset = end
        }

        // 3. Receiver pipeline
        let recvPayload = try PeerMessage.decoded(from: metaWire).decodePayload(MediaMessagePayload.self)
        XCTAssertEqual(recvPayload.duration, 12.7)
        XCTAssertEqual(recvPayload.thumbnailData, thumbnail)

        var pendingData = Data()
        for wire in wireChunks { pendingData.append(try PeerMessage.decoded(from: wire).payload!) }

        receiverChatManager.saveIncomingMedia(
            payload: recvPayload, fileData: pendingData,
            peerID: senderID, peerName: "VideoSender"
        )

        // 4. Verify
        receiverChatManager.loadMessages(forPeer: senderID)
        let msg = receiverChatManager.messages[0]
        XCTAssertEqual(msg.mediaType, "video")
        XCTAssertEqual(msg.fileName, "clip.mp4")
        XCTAssertEqual(msg.duration, 12.7)
        XCTAssertEqual(msg.thumbnailData, thumbnail)

        let savedData = try Data(contentsOf: receiverChatManager.resolveMediaURL(msg.localFileURL!))
        XCTAssertEqual(savedData, videoData, "Video data should match original byte-for-byte")

        receiverChatManager.deleteMessages(forPeer: senderID)
    }

    /// Full bidirectional exchange: Alice sends image, Bob sends voice — single ChatManager simulates both receives
    @MainActor
    func testFullPipelineBidirectionalExchange() async throws {
        let chatManager = ChatManager()
        let aliceID = "alice-\(UUID().uuidString.prefix(8))"
        let bobID = "bob-\(UUID().uuidString.prefix(8))"

        // --- Alice sends image → Bob receives ---
        let imageData = Data((0..<30_000).map { _ in UInt8.random(in: 0...255) })
        let imgPayload = MediaMessagePayload(
            mediaType: .image, fileName: "selfie.jpg",
            fileSize: Int64(imageData.count), mimeType: "image/jpeg",
            duration: nil, thumbnailData: Data([0xFF])
        )
        let imgMetaWire = try PeerMessage.mediaMessage(imgPayload, senderID: aliceID).encoded()
        let imgChunkWire = try PeerMessage.fileChunk(imageData, senderID: aliceID).encoded()

        // Bob's side receives (peerID = aliceID)
        let bobRecvPayload = try PeerMessage.decoded(from: imgMetaWire).decodePayload(MediaMessagePayload.self)
        let bobRecvData = try PeerMessage.decoded(from: imgChunkWire).payload!
        chatManager.saveIncomingMedia(payload: bobRecvPayload, fileData: bobRecvData, peerID: aliceID, peerName: "Alice")

        // --- Bob sends voice → Alice receives ---
        let voiceData = Data((0..<5_000).map { _ in UInt8.random(in: 0...255) })
        let voicePayload = MediaMessagePayload(
            mediaType: .voice, fileName: "reply.m4a",
            fileSize: Int64(voiceData.count), mimeType: "audio/m4a",
            duration: 2.1, thumbnailData: nil
        )
        let voiceMetaWire = try PeerMessage.mediaMessage(voicePayload, senderID: bobID).encoded()
        let voiceChunkWire = try PeerMessage.fileChunk(voiceData, senderID: bobID).encoded()

        // Alice's side receives (peerID = bobID)
        let aliceRecvPayload = try PeerMessage.decoded(from: voiceMetaWire).decodePayload(MediaMessagePayload.self)
        let aliceRecvData = try PeerMessage.decoded(from: voiceChunkWire).payload!
        chatManager.saveIncomingMedia(payload: aliceRecvPayload, fileData: aliceRecvData, peerID: bobID, peerName: "Bob")

        // --- Verify Bob's received messages (from Alice) ---
        chatManager.loadMessages(forPeer: aliceID)
        XCTAssertEqual(chatManager.messages.count, 1)
        let bobMsg = chatManager.messages[0]
        XCTAssertEqual(bobMsg.mediaType, "image")
        XCTAssertEqual(bobMsg.peerName, "Alice")
        let bobSavedData = try Data(contentsOf: chatManager.resolveMediaURL(bobMsg.localFileURL!))
        XCTAssertEqual(bobSavedData, imageData)

        // --- Verify Alice's received messages (from Bob) ---
        chatManager.loadMessages(forPeer: bobID)
        XCTAssertEqual(chatManager.messages.count, 1)
        let aliceMsg = chatManager.messages[0]
        XCTAssertEqual(aliceMsg.mediaType, "voice")
        XCTAssertEqual(aliceMsg.duration, 2.1)
        XCTAssertEqual(aliceMsg.peerName, "Bob")
        let aliceSavedData = try Data(contentsOf: chatManager.resolveMediaURL(aliceMsg.localFileURL!))
        XCTAssertEqual(aliceSavedData, voiceData)

        // Clean up
        chatManager.deleteMessages(forPeer: aliceID)
        chatManager.deleteMessages(forPeer: bobID)
    }

    @MainActor
    func testMessageStatusUpdate() async throws {
        let chatManager = ChatManager()
        let peerID = "status-test-\(UUID().uuidString.prefix(8))"

        let msg = chatManager.saveOutgoingMedia(
            mediaType: .file,
            fileName: "doc.pdf",
            fileSize: 1000,
            mimeType: "application/pdf",
            duration: nil,
            localFileURL: "\(peerID)/doc.pdf",
            thumbnailData: nil,
            peerID: peerID,
            peerName: "Peer"
        )

        XCTAssertEqual(msg.status, .sending)

        // Update status to sent
        chatManager.updateStatus(messageID: msg.id, status: .sent)

        // Reload and verify
        chatManager.loadMessages(forPeer: peerID)
        XCTAssertEqual(chatManager.messages.first?.status, .sent)

        // Clean up
        chatManager.deleteMessages(forPeer: peerID)
    }
}
