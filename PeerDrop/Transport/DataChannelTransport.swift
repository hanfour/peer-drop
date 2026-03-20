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
            return try PeerMessage.decoded(from: data)
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

    private func handleReceivedData(_ data: Data) {
        guard let parsed = Self.parseChunkHeader(data) else {
            logger.warning("Received malformed chunk data (\(data.count) bytes)")
            return
        }

        let (_, messageID, chunkIndex, totalChunks, payload) = parsed

        if totalChunks == 1 {
            // Single-chunk message, deliver immediately
            receiveContinuation.yield(payload)
            return
        }

        // Multi-chunk reassembly keyed by messageID — synchronized
        let assembled: Data? = queue.sync {
            // Purge expired entries
            reassemblyBuffer = reassemblyBuffer.filter { !$0.value.isExpired }

            if reassemblyBuffer[messageID] == nil {
                reassemblyBuffer[messageID] = ReassemblyState(
                    totalChunks: totalChunks
                )
            }

            reassemblyBuffer[messageID]?.chunks[chunkIndex] = payload

            if reassemblyBuffer[messageID]?.isComplete == true {
                let result = reassemblyBuffer[messageID]!.assemble()
                reassemblyBuffer.removeValue(forKey: messageID)
                return result
            }
            return nil
        }

        if let assembled {
            logger.debug("Reassembled \(totalChunks) chunks → \(assembled.count) bytes")
            receiveContinuation.yield(assembled)
        }
    }
}
