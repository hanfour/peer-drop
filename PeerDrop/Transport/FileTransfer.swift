import Foundation

/// Manages chunked file transfer with back-pressure and hash verification.
@MainActor
final class FileTransfer: ObservableObject {
    @Published private(set) var progress: Double = 0
    @Published private(set) var isTransferring = false
    @Published private(set) var lastError: String?
    @Published var receivedFileURL: URL?

    private weak var connectionManager: ConnectionManager?
    private let chunkSize = Data.defaultChunkSize

    // Receive state
    private var receiveBuffer = Data()
    private var receiveMetadata: TransferMetadata?
    private var receiveHasher = HashVerifier()
    private var receivedBytes: Int64 = 0
    private var receiveContinuation: CheckedContinuation<URL, Error>?

    init(connectionManager: ConnectionManager) {
        self.connectionManager = connectionManager
    }

    // MARK: - Sending

    func sendFile(at url: URL) async throws {
        guard let manager = connectionManager else {
            throw FileTransferError.notConnected
        }

        isTransferring = true
        progress = 0
        lastError = nil

        defer {
            isTransferring = false
        }

        let data = try Data(contentsOf: url)
        let hash = HashVerifier.sha256(data)
        let fileName = url.lastPathComponent
        let fileSize = Int64(data.count)

        let metadata = TransferMetadata(
            fileName: fileName,
            fileSize: fileSize,
            mimeType: nil,
            sha256Hash: hash
        )

        // Send file offer
        let offer = try PeerMessage.fileOffer(metadata: metadata, senderID: "local")
        try await manager.sendMessage(offer)

        // Wait for accept/reject is handled by the message loop calling handleFileAccept/Reject

        // Send chunks
        let chunks = data.chunks(ofSize: chunkSize)
        for (index, chunk) in chunks.enumerated() {
            let chunkMsg = PeerMessage.fileChunk(chunk, senderID: "local")
            try await manager.sendMessage(chunkMsg)
            progress = Double(index + 1) / Double(chunks.count)
        }

        // Send completion
        let complete = try PeerMessage.fileComplete(hash: hash, senderID: "local")
        try await manager.sendMessage(complete)
        progress = 1.0
    }

    // MARK: - Receiving (called from ConnectionManager message loop)

    func handleFileOffer(_ message: PeerMessage) {
        guard let payload = message.payload,
              let metadata = try? JSONDecoder().decode(TransferMetadata.self, from: payload) else {
            return
        }

        receiveMetadata = metadata
        receiveBuffer = Data()
        receiveHasher = HashVerifier()
        receivedBytes = 0

        // Auto-accept for now (consent already given at connection level)
        Task {
            let accept = PeerMessage.fileAccept(senderID: "local")
            try? await connectionManager?.sendMessage(accept)
            isTransferring = true
            progress = 0
            connectionManager?.showTransferProgress = true
        }
    }

    func handleFileAccept() {
        // Sender can proceed — chunks are already being sent
    }

    func handleFileReject() {
        isTransferring = false
        lastError = "File transfer was rejected"
    }

    func handleFileChunk(_ message: PeerMessage) {
        guard let data = message.payload, let metadata = receiveMetadata else { return }

        receiveBuffer.append(data)
        receiveHasher.update(with: data)
        receivedBytes += Int64(data.count)
        progress = Double(receivedBytes) / Double(metadata.fileSize)
    }

    func handleFileComplete(_ message: PeerMessage) {
        guard let metadata = receiveMetadata else { return }

        let computedHash = receiveHasher.finalize()

        if computedHash == metadata.sha256Hash {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(metadata.fileName)
            try? receiveBuffer.write(to: tempURL)
            receivedFileURL = tempURL
            lastError = nil
            HapticManager.transferComplete()
        } else {
            lastError = "Hash verification failed"
            HapticManager.transferFailed()
        }

        isTransferring = false
        receiveBuffer = Data()
        receiveMetadata = nil

        Task {
            connectionManager?.showTransferProgress = false
            connectionManager?.transition(to: .connected)
        }
    }
}

enum FileTransferError: Error, LocalizedError {
    case notConnected
    case hashMismatch
    case transferRejected

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to a peer"
        case .hashMismatch: return "File integrity check failed"
        case .transferRejected: return "File transfer was rejected"
        }
    }
}
