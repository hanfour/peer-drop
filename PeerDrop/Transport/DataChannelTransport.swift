import Foundation
import os

private let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "DataChannelTransport")

/// Adapts a DataChannelClient to the TransportProtocol interface.
/// Handles 64KB chunking for large messages.
final class DataChannelTransport: TransportProtocol {

    // MARK: - Constants

    /// Maximum payload per WebRTC DataChannel message (safe limit under 64KB).
    static let maxChunkPayload = 60_000
    /// Header: [4B total length][2B message ID][2B chunk index][2B total chunks]
    static let chunkHeaderSize = 10

    /// Max total bytes reserved across all in-flight reassembly states.
    /// Prevents memory DoS from an attacker sending many partial messages.
    /// 256 MB covers every legitimate PeerDrop payload (largest media ~100 MB).
    private static let maxReassemblyTotalBytes: Int = 256 * 1024 * 1024
    /// Max concurrent partial messages (prevents key-space attack).
    private static let maxReassemblyEntries: Int = 32

    // MARK: - Reassembly Rejection

    /// Reasons an incoming chunk may be rejected during reassembly.
    /// Surfaced via `onReassemblyRejected` for metrics and tests.
    enum ReassemblyRejectReason: String {
        case chunkIndexOutOfRange
        case totalChunksInvalid
        case duplicateChunk
        case bufferTotalBytesExceeded
        case bufferEntryCountExceeded
    }

    /// Called when an incoming chunk is rejected. Useful for metrics + tests.
    /// MainActor dispatch not guaranteed — caller should hop if needed.
    var onReassemblyRejected: ((ReassemblyRejectReason) -> Void)?

    /// Test-only accessor for the current buffer state.
    var reassemblyBufferCount: Int {
        queue.sync { reassemblyBuffer.count }
    }

    // MARK: - Properties

    let client: DataChannelClient
    var onStateChange: ((TransportState) -> Void)?

    private let receiveStream: AsyncStream<Data>
    private let receiveContinuation: AsyncStream<Data>.Continuation

    /// Serial queue protecting mutable state (nextMessageID, reassemblyBuffer, _isReady).
    private let queue = DispatchQueue(label: "com.hanfour.peerdrop.DataChannelTransport")

    /// Monotonically increasing message ID for chunked sends.
    private var nextMessageID: UInt16 = 0
    /// Reassembly buffer for chunked messages, keyed by message ID.
    private var reassemblyBuffer: [UInt16: ReassemblyState] = [:]

    /// Stale reassembly entries older than this are purged.
    private static let reassemblyTimeout: TimeInterval = 30

    private struct ReassemblyState {
        let totalChunks: UInt16
        var chunks: [UInt16: Data]
        let createdAt: Date

        init(totalChunks: UInt16, chunks: [UInt16: Data] = [:]) {
            self.totalChunks = totalChunks
            self.chunks = chunks
            self.createdAt = Date()
        }

        var isComplete: Bool { chunks.count == Int(totalChunks) }

        var isExpired: Bool {
            Date().timeIntervalSince(createdAt) > DataChannelTransport.reassemblyTimeout
        }

        func assemble() -> Data {
            var result = Data()
            for i in 0..<totalChunks {
                if let chunk = chunks[i] {
                    result.append(chunk)
                }
            }
            return result
        }
    }

    // MARK: - Init

    init(client: DataChannelClient) {
        self.client = client

        var continuation: AsyncStream<Data>.Continuation!
        self.receiveStream = AsyncStream { c in
            continuation = c
        }
        self.receiveContinuation = continuation

        setupCallbacks()
    }

    // MARK: - TransportProtocol

    var isReady: Bool {
        queue.sync { _isReady }
    }
    private var _isReady = false

    func send(_ message: PeerMessage) async throws {
        let data = try message.encoded()
        let messageID = queue.sync { () -> UInt16 in
            let id = nextMessageID
            nextMessageID &+= 1
            return id
        }

        if data.count <= Self.maxChunkPayload {
            // Single message, no chunking needed. Wrap with header indicating 1 chunk.
            let packet = Self.makeChunkPacket(
                totalLength: UInt32(data.count),
                messageID: messageID,
                chunkIndex: 0,
                totalChunks: 1,
                payload: data
            )
            guard client.send(packet) else {
                throw DataChannelError.sendFailed
            }
        } else {
            // Chunk the message
            let totalLength = UInt32(data.count)
            let chunkPayloadSize = Self.maxChunkPayload
            let totalChunks = UInt16((data.count + chunkPayloadSize - 1) / chunkPayloadSize)

            for i in 0..<Int(totalChunks) {
                let start = i * chunkPayloadSize
                let end = min(start + chunkPayloadSize, data.count)
                let chunkData = data[start..<end]

                let packet = Self.makeChunkPacket(
                    totalLength: totalLength,
                    messageID: messageID,
                    chunkIndex: UInt16(i),
                    totalChunks: totalChunks,
                    payload: Data(chunkData)
                )
                guard client.send(packet) else {
                    throw DataChannelError.sendFailed
                }
            }
            logger.debug("Sent \(totalChunks) chunks for \(data.count) bytes")
        }
    }

    func receive() async throws -> PeerMessage {
        for await data in receiveStream {
            do {
                return try PeerMessage.decoded(from: data)
            } catch {
                logger.warning("Skipping malformed message (\(data.count) bytes): \(error.localizedDescription)")
                continue
            }
        }
        throw DataChannelError.dataChannelClosed
    }

    func close() {
        receiveContinuation.finish()
        client.close()
        queue.sync { _isReady = false }
        onStateChange?(.cancelled)
    }

    // MARK: - Chunk Protocol

    /// Packet format: [4B totalLength][2B messageID][2B chunkIndex][2B totalChunks][payload]
    static func makeChunkPacket(totalLength: UInt32, messageID: UInt16 = 0, chunkIndex: UInt16, totalChunks: UInt16, payload: Data) -> Data {
        var packet = Data(capacity: chunkHeaderSize + payload.count)
        var tl = totalLength.bigEndian
        var mi = messageID.bigEndian
        var ci = chunkIndex.bigEndian
        var tc = totalChunks.bigEndian
        packet.append(Data(bytes: &tl, count: 4))
        packet.append(Data(bytes: &mi, count: 2))
        packet.append(Data(bytes: &ci, count: 2))
        packet.append(Data(bytes: &tc, count: 2))
        packet.append(payload)
        return packet
    }

    static func parseChunkHeader(_ data: Data) -> (totalLength: UInt32, messageID: UInt16, chunkIndex: UInt16, totalChunks: UInt16, payload: Data)? {
        guard data.count >= chunkHeaderSize else { return nil }
        let totalLength = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self).bigEndian }
        let messageID = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt16.self).bigEndian }
        let chunkIndex = data.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self).bigEndian }
        let totalChunks = data.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt16.self).bigEndian }
        let payload = data.subdata(in: chunkHeaderSize..<data.count)
        return (totalLength, messageID, chunkIndex, totalChunks, payload)
    }

    // MARK: - Private

    private func setupCallbacks() {
        client.onDataChannelOpen = { [weak self] in
            guard let self else { return }
            self.queue.sync { self._isReady = true }
            self.onStateChange?(.ready)
        }

        client.onDataChannelClose = { [weak self] in
            guard let self else { return }
            self.queue.sync { self._isReady = false }
            self.onStateChange?(.cancelled)
            self.receiveContinuation.finish()
        }

        client.onConnectionStateChange = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed:
                self.queue.sync { self._isReady = false }
                self.onStateChange?(.failed(DataChannelError.dataChannelClosed))
                self.receiveContinuation.finish()
            case .disconnected:
                self.queue.sync { self._isReady = false }
                self.onStateChange?(.cancelled)
                self.receiveContinuation.finish()
            default:
                break
            }
        }

        client.onDataReceived = { [weak self] data in
            self?.handleReceivedData(data)
        }
    }

    /// Exposed as `internal` (not `private`) so tests can inject crafted chunks
    /// without constructing a real WebRTC data-channel client.
    func handleReceivedData(_ data: Data) {
        guard let parsed = Self.parseChunkHeader(data) else {
            logger.warning("Received malformed chunk data (\(data.count) bytes)")
            return
        }

        let (_, messageID, chunkIndex, totalChunks, payload) = parsed

        // Reject nonsensical totalChunks (0 or chunkIndex out of range)
        guard totalChunks > 0 else {
            logger.warning("Rejecting chunk: totalChunks=0")
            onReassemblyRejected?(.totalChunksInvalid)
            return
        }
        guard chunkIndex < totalChunks else {
            logger.warning("Rejecting chunk: index \(chunkIndex) out of range (total=\(totalChunks))")
            onReassemblyRejected?(.chunkIndexOutOfRange)
            return
        }

        if totalChunks == 1 {
            // Single-chunk message, deliver immediately
            receiveContinuation.yield(payload)
            return
        }

        // Multi-chunk reassembly keyed by messageID — synchronized
        var rejectReason: ReassemblyRejectReason?
        let assembled: Data? = queue.sync {
            // Purge expired entries
            reassemblyBuffer = reassemblyBuffer.filter { !$0.value.isExpired }

            // Estimate bytes if we create a new entry. This is a rough cap
            // based on already-received chunks; real payloads are typically
            // smaller than the per-chunk maximum.
            let currentBytes = reassemblyBuffer.values.reduce(0) { acc, state in
                acc + state.chunks.values.reduce(0) { $0 + $1.count }
            }

            if reassemblyBuffer[messageID] == nil {
                // Cap concurrent partial messages
                guard reassemblyBuffer.count < Self.maxReassemblyEntries else {
                    rejectReason = .bufferEntryCountExceeded
                    return nil
                }
                reassemblyBuffer[messageID] = ReassemblyState(
                    totalChunks: totalChunks
                )
            }

            // Cap total buffered bytes before adding this chunk.
            // Dropping a chunk leaves the existing partial state intact so it
            // can still complete if the sender retries; it simply won't grow.
            guard currentBytes + payload.count <= Self.maxReassemblyTotalBytes else {
                rejectReason = .bufferTotalBytesExceeded
                return nil
            }

            // Detect duplicate chunks with a conflicting payload for the same
            // index — likely an attack or a peer bug. Benign replays with
            // identical bytes are silently accepted.
            if let existing = reassemblyBuffer[messageID]?.chunks[chunkIndex],
               existing != payload {
                rejectReason = .duplicateChunk
                return nil
            }

            reassemblyBuffer[messageID]?.chunks[chunkIndex] = payload

            if reassemblyBuffer[messageID]?.isComplete == true {
                let result = reassemblyBuffer[messageID]!.assemble()
                reassemblyBuffer.removeValue(forKey: messageID)
                return result
            }
            return nil
        }

        if let rejectReason {
            onReassemblyRejected?(rejectReason)
            return
        }

        if let assembled {
            logger.debug("Reassembled \(totalChunks) chunks → \(assembled.count) bytes")
            receiveContinuation.yield(assembled)
        }
    }
}
