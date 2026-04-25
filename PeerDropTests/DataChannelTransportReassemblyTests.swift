import XCTest
@testable import PeerDrop

/// Exercises the reassembly hardening in `DataChannelTransport` (A.1).
///
/// We construct a real `DataChannelClient` but never call `setup` on it, so
/// no RTCPeerConnection is created. `handleReceivedData` is exposed as
/// `internal` for these tests, letting us inject crafted chunks directly.
final class DataChannelTransportReassemblyTests: XCTestCase {

    func test_chunkIndexOutOfRange_isRejected() {
        let transport = makeTransport()
        var reason: DataChannelTransport.ReassemblyRejectReason?
        transport.onReassemblyRejected = { reason = $0 }

        // chunkIndex=5 but totalChunks=3 — invalid
        let packet = DataChannelTransport.makeChunkPacket(
            totalLength: 100,
            messageID: 1,
            chunkIndex: 5,
            totalChunks: 3,
            payload: Data(count: 10)
        )
        transport.handleReceivedData(packet)

        XCTAssertEqual(reason, .chunkIndexOutOfRange)
        XCTAssertEqual(transport.reassemblyBufferCount, 0)
    }

    func test_totalChunksZero_isRejected() {
        let transport = makeTransport()
        var reason: DataChannelTransport.ReassemblyRejectReason?
        transport.onReassemblyRejected = { reason = $0 }

        let packet = DataChannelTransport.makeChunkPacket(
            totalLength: 100,
            messageID: 1,
            chunkIndex: 0,
            totalChunks: 0,
            payload: Data(count: 10)
        )
        transport.handleReceivedData(packet)

        XCTAssertEqual(reason, .totalChunksInvalid)
        XCTAssertEqual(transport.reassemblyBufferCount, 0)
    }

    func test_tooManyConcurrentMessages_rejected() {
        let transport = makeTransport()
        var lastReason: DataChannelTransport.ReassemblyRejectReason?
        transport.onReassemblyRejected = { lastReason = $0 }

        // Fill buffer with 32 distinct messageIDs, each 1 chunk of a 2-chunk message
        for i in 0..<32 {
            let packet = DataChannelTransport.makeChunkPacket(
                totalLength: 200,
                messageID: UInt16(i),
                chunkIndex: 0,
                totalChunks: 2,
                payload: Data(count: 100)
            )
            transport.handleReceivedData(packet)
        }
        XCTAssertEqual(transport.reassemblyBufferCount, 32)

        // 33rd distinct messageID should be rejected
        let excess = DataChannelTransport.makeChunkPacket(
            totalLength: 200,
            messageID: 9999,
            chunkIndex: 0,
            totalChunks: 2,
            payload: Data(count: 100)
        )
        transport.handleReceivedData(excess)

        XCTAssertEqual(lastReason, .bufferEntryCountExceeded)
        XCTAssertEqual(transport.reassemblyBufferCount, 32)
    }

    func test_duplicateChunkWithDifferentPayload_rejected() {
        let transport = makeTransport()
        var reason: DataChannelTransport.ReassemblyRejectReason?
        transport.onReassemblyRejected = { reason = $0 }

        // Capture the assembled bytes so we can verify the original chunk
        // survived the attacker's conflicting replay.
        var assembled: Data?
        transport.onAssembledDataForTesting = { assembled = $0 }

        let first = DataChannelTransport.makeChunkPacket(
            totalLength: 4,
            messageID: 1,
            chunkIndex: 0,
            totalChunks: 2,
            payload: Data([0xAA, 0xBB])
        )
        let attacker = DataChannelTransport.makeChunkPacket(
            totalLength: 4,
            messageID: 1,
            chunkIndex: 0,
            totalChunks: 2,
            payload: Data([0xCC, 0xDD])
        )
        transport.handleReceivedData(first)
        transport.handleReceivedData(attacker)

        XCTAssertEqual(reason, .duplicateChunk)
        // Original entry should still be present (we drop the offending chunk only).
        XCTAssertEqual(transport.reassemblyBufferCount, 1)

        // Complete the message with a legitimate second chunk and verify the
        // assembled bytes preserve the ORIGINAL first chunk, not the attacker's.
        let second = DataChannelTransport.makeChunkPacket(
            totalLength: 4,
            messageID: 1,
            chunkIndex: 1,
            totalChunks: 2,
            payload: Data([0x11, 0x22])
        )
        transport.handleReceivedData(second)

        XCTAssertEqual(assembled, Data([0xAA, 0xBB, 0x11, 0x22]))
        XCTAssertEqual(transport.reassemblyBufferCount, 0)
    }

    func test_declaredTotalLengthExceedingCap_isRejected() {
        let transport = makeTransport()
        var reason: DataChannelTransport.ReassemblyRejectReason?
        transport.onReassemblyRejected = { reason = $0 }

        // Attacker declares a 4 GB message in the header. Must be rejected
        // upfront — before any buffer entry is created.
        let packet = DataChannelTransport.makeChunkPacket(
            totalLength: UInt32.max,
            messageID: 1,
            chunkIndex: 0,
            totalChunks: 100,
            payload: Data(count: 10)
        )
        transport.handleReceivedData(packet)

        XCTAssertEqual(reason, .messageTooLarge)
        XCTAssertEqual(transport.reassemblyBufferCount, 0)
    }

    func test_identicalDuplicateChunk_isAccepted() {
        let transport = makeTransport()
        var reason: DataChannelTransport.ReassemblyRejectReason?
        transport.onReassemblyRejected = { reason = $0 }

        let packet = DataChannelTransport.makeChunkPacket(
            totalLength: 200,
            messageID: 1,
            chunkIndex: 0,
            totalChunks: 2,
            payload: Data([0xAA, 0xBB])
        )
        transport.handleReceivedData(packet)
        transport.handleReceivedData(packet)

        XCTAssertNil(reason)
        XCTAssertEqual(transport.reassemblyBufferCount, 1)
    }

    func test_singleChunkMessage_bypassesBuffer() {
        let transport = makeTransport()
        var reason: DataChannelTransport.ReassemblyRejectReason?
        transport.onReassemblyRejected = { reason = $0 }

        let packet = DataChannelTransport.makeChunkPacket(
            totalLength: 10,
            messageID: 1,
            chunkIndex: 0,
            totalChunks: 1,
            payload: Data(count: 10)
        )
        transport.handleReceivedData(packet)

        XCTAssertNil(reason)
        XCTAssertEqual(transport.reassemblyBufferCount, 0)
    }

    // MARK: - Helpers

    private func makeTransport() -> DataChannelTransport {
        // `DataChannelClient` is a concrete class but is safe to instantiate
        // without calling `setup(with:)`. `handleReceivedData` never touches
        // the underlying peer connection.
        let client = DataChannelClient()
        return DataChannelTransport(client: client)
    }
}
