import XCTest
@testable import PeerDrop

final class BLESignalingTests: XCTestCase {

    // MARK: - Chunk Tests

    func testChunkSmallData() {
        let data = Data("Hello".utf8)
        let chunks = BLESignaling.chunkData(data)

        XCTAssertEqual(chunks.count, 1)

        // First (and only) chunk should have both first and last flags
        let flags = chunks[0][0]
        XCTAssertEqual(flags & 0x01, 0x01, "First flag should be set")
        XCTAssertEqual(flags & 0x02, 0x02, "Last flag should be set")

        // Payload should be the original data
        let payload = chunks[0].dropFirst()
        XCTAssertEqual(Data(payload), data)
    }

    func testChunkLargeData() {
        // Create data larger than maxChunkPayload (480 bytes)
        let data = Data(repeating: 0xAA, count: 1000)
        let chunks = BLESignaling.chunkData(data)

        // 1000 / 480 = 2.08, so 3 chunks
        XCTAssertEqual(chunks.count, 3)

        // First chunk: first flag only
        XCTAssertEqual(chunks[0][0] & 0x01, 0x01, "First chunk should have first flag")
        XCTAssertEqual(chunks[0][0] & 0x02, 0x00, "First chunk should not have last flag")

        // Middle chunk: no flags
        XCTAssertEqual(chunks[1][0], 0x00, "Middle chunk should have no flags")

        // Last chunk: last flag only
        XCTAssertEqual(chunks[2][0] & 0x01, 0x00, "Last chunk should not have first flag")
        XCTAssertEqual(chunks[2][0] & 0x02, 0x02, "Last chunk should have last flag")

        // Reassemble and verify
        var reassembled = Data()
        for chunk in chunks {
            reassembled.append(chunk.dropFirst())
        }
        XCTAssertEqual(reassembled, data)
    }

    func testChunkExactMultiple() {
        // Exactly 480 bytes — single chunk
        let data = Data(repeating: 0xBB, count: 480)
        let chunks = BLESignaling.chunkData(data)
        XCTAssertEqual(chunks.count, 1)
    }

    func testChunkEmptyData() {
        let data = Data()
        let chunks = BLESignaling.chunkData(data)
        XCTAssertEqual(chunks.count, 1)
        // Should have both first and last flags
        XCTAssertEqual(chunks[0][0], 0x03)
    }

    func testChunkPayloadSize() {
        // Each chunk payload should be at most 480 bytes
        let data = Data(repeating: 0xCC, count: 960)
        let chunks = BLESignaling.chunkData(data)

        for chunk in chunks {
            let payloadSize = chunk.count - 1 // minus 1 byte for flags
            XCTAssertLessThanOrEqual(payloadSize, BLESignaling.maxChunkPayload)
        }
    }

    // MARK: - Reassembly Tests

    func testProcessSingleChunk() {
        let signaling = BLESignaling()
        let data = Data("Test message".utf8)
        let chunks = BLESignaling.chunkData(data)

        let uuid = BLESignaling.sdpOfferUUID
        let result = signaling.processChunk(chunks[0], for: uuid)

        XCTAssertNotNil(result)
        XCTAssertEqual(result, data)
    }

    func testProcessMultiChunks() {
        let signaling = BLESignaling()
        let data = Data(repeating: 0xDD, count: 1000)
        let chunks = BLESignaling.chunkData(data)
        let uuid = BLESignaling.sdpAnswerUUID

        // Process first chunks — should return nil
        for chunk in chunks.dropLast() {
            let result = signaling.processChunk(chunk, for: uuid)
            XCTAssertNil(result, "Intermediate chunks should not produce a result")
        }

        // Process last chunk — should return assembled data
        let result = signaling.processChunk(chunks.last!, for: uuid)
        XCTAssertNotNil(result)
        XCTAssertEqual(result, data)
    }

    func testProcessEmptyChunk() {
        let signaling = BLESignaling()
        let result = signaling.processChunk(Data(), for: BLESignaling.controlUUID)
        XCTAssertNil(result)
    }
}
