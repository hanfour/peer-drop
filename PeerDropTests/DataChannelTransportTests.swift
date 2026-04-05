import XCTest
@testable import PeerDrop

final class DataChannelTransportTests: XCTestCase {

    // MARK: - Chunk Protocol Tests

    func testMakeAndParseChunkPacket() {
        let payload = Data("Hello, World!".utf8)
        let packet = DataChannelTransport.makeChunkPacket(
            totalLength: 100,
            messageID: 7,
            chunkIndex: 2,
            totalChunks: 5,
            payload: payload
        )

        let parsed = DataChannelTransport.parseChunkHeader(packet)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.totalLength, 100)
        XCTAssertEqual(parsed?.messageID, 7)
        XCTAssertEqual(parsed?.chunkIndex, 2)
        XCTAssertEqual(parsed?.totalChunks, 5)
        XCTAssertEqual(parsed?.payload, payload)
    }

    func testSingleChunkPacket() {
        let payload = Data("Short message".utf8)
        let packet = DataChannelTransport.makeChunkPacket(
            totalLength: UInt32(payload.count),
            messageID: 0,
            chunkIndex: 0,
            totalChunks: 1,
            payload: payload
        )

        let parsed = DataChannelTransport.parseChunkHeader(packet)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.totalChunks, 1)
        XCTAssertEqual(parsed?.chunkIndex, 0)
        XCTAssertEqual(parsed?.payload, payload)
    }

    func testParseInvalidPacket() {
        // Too short — less than header size (10 bytes)
        let shortData = Data([0x01, 0x02, 0x03])
        let parsed = DataChannelTransport.parseChunkHeader(shortData)
        XCTAssertNil(parsed)
    }

    func testParseEmptyPayload() {
        // Header only, no payload
        let packet = DataChannelTransport.makeChunkPacket(
            totalLength: 0,
            messageID: 0,
            chunkIndex: 0,
            totalChunks: 1,
            payload: Data()
        )

        let parsed = DataChannelTransport.parseChunkHeader(packet)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.payload.count, 0)
    }

    func testLargePayloadChunking() {
        // Simulate what would happen with a large message
        let largePayload = Data(repeating: 0xAB, count: 150_000)
        let maxChunk = DataChannelTransport.maxChunkPayload
        let totalChunks = UInt16((largePayload.count + maxChunk - 1) / maxChunk)

        XCTAssertEqual(totalChunks, 3) // 150KB / 60KB = 2.5, ceil = 3

        // Create all chunks with a messageID
        let messageID: UInt16 = 42
        var chunks: [Data] = []
        for i in 0..<Int(totalChunks) {
            let start = i * maxChunk
            let end = min(start + maxChunk, largePayload.count)
            let chunkData = largePayload[start..<end]

            let packet = DataChannelTransport.makeChunkPacket(
                totalLength: UInt32(largePayload.count),
                messageID: messageID,
                chunkIndex: UInt16(i),
                totalChunks: totalChunks,
                payload: Data(chunkData)
            )
            chunks.append(packet)
        }

        // Parse and reassemble
        var reassembled = Data()
        for chunk in chunks {
            let parsed = DataChannelTransport.parseChunkHeader(chunk)!
            XCTAssertEqual(parsed.messageID, messageID)
            reassembled.append(parsed.payload)
        }

        XCTAssertEqual(reassembled.count, largePayload.count)
        XCTAssertEqual(reassembled, largePayload)
    }

    func testChunkHeaderSize() {
        XCTAssertEqual(DataChannelTransport.chunkHeaderSize, 10)
    }

    func testMaxChunkPayload() {
        XCTAssertEqual(DataChannelTransport.maxChunkPayload, 60_000)
    }

    func testBigEndianEncoding() {
        // Verify big-endian encoding is correct
        let packet = DataChannelTransport.makeChunkPacket(
            totalLength: 0x00010000, // 65536
            messageID: 0x0003,
            chunkIndex: 0x0001,
            totalChunks: 0x0002,
            payload: Data([0xFF])
        )

        let parsed = DataChannelTransport.parseChunkHeader(packet)!
        XCTAssertEqual(parsed.totalLength, 65536)
        XCTAssertEqual(parsed.messageID, 3)
        XCTAssertEqual(parsed.chunkIndex, 1)
        XCTAssertEqual(parsed.totalChunks, 2)
        XCTAssertEqual(parsed.payload, Data([0xFF]))
    }

    func testDifferentMessageIDsDoNotCollide() {
        // Two messages with the same total length but different messageIDs
        let payload1 = Data("Message A".utf8)
        let payload2 = Data("Message B".utf8)

        let packet1 = DataChannelTransport.makeChunkPacket(
            totalLength: UInt32(payload1.count),
            messageID: 1,
            chunkIndex: 0,
            totalChunks: 1,
            payload: payload1
        )
        let packet2 = DataChannelTransport.makeChunkPacket(
            totalLength: UInt32(payload2.count),
            messageID: 2,
            chunkIndex: 0,
            totalChunks: 1,
            payload: payload2
        )

        let parsed1 = DataChannelTransport.parseChunkHeader(packet1)!
        let parsed2 = DataChannelTransport.parseChunkHeader(packet2)!

        XCTAssertEqual(parsed1.totalLength, parsed2.totalLength) // same length
        XCTAssertNotEqual(parsed1.messageID, parsed2.messageID) // different IDs
        XCTAssertNotEqual(parsed1.payload, parsed2.payload)
    }
}
