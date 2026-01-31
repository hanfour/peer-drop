import Foundation

/// Manages chunked file transfer with back-pressure and hash verification.
@MainActor
final class FileTransfer: ObservableObject {
    @Published private(set) var progress: Double = 0
    @Published private(set) var isTransferring = false
    @Published private(set) var lastError: String?
    @Published private(set) var currentFileName: String?
    @Published var receivedFileURL: URL?
    @Published var receivedFileURLs: [URL] = []
    @Published private(set) var currentFileIndex: Int = 0
    @Published private(set) var totalFileCount: Int = 0
    @Published private(set) var overallProgress: Double = 0
    @Published private(set) var isCurrentTransferDirectory: Bool = false

    private weak var connectionManager: ConnectionManager?
    private let chunkSize = Data.defaultChunkSize
    private var isCancelled = false

    // Receive state
    private var receiveBuffer = Data()
    private var receiveMetadata: TransferMetadata?
    private var receiveHasher = HashVerifier()
    private var receivedBytes: Int64 = 0
    private var receiveContinuation: CheckedContinuation<URL, Error>?

    // Batch receive state
    private var batchMetadata: BatchMetadata?
    private var batchReceivedURLs: [URL] = []
    private var batchFilesCompleted: Int = 0

    init(connectionManager: ConnectionManager) {
        self.connectionManager = connectionManager
    }

    // MARK: - Sending

    func sendFiles(at urls: [URL], directoryFlags: [URL: Bool] = [:]) async throws {
        defer {
            currentFileIndex = 0
            totalFileCount = 0
        }

        totalFileCount = urls.count

        for (index, url) in urls.enumerated() {
            guard !isCancelled else { throw FileTransferError.cancelled }

            currentFileIndex = index + 1

            guard url.startAccessingSecurityScopedResource() else { continue }
            defer { url.stopAccessingSecurityScopedResource() }

            let isDirectory = directoryFlags[url] ?? false
            try await sendFile(at: url, isDirectory: isDirectory)
        }
    }

    func sendFile(at url: URL, isDirectory: Bool = false) async throws {
        guard let manager = connectionManager else {
            throw FileTransferError.notConnected
        }

        isTransferring = true
        isCancelled = false
        progress = 0
        lastError = nil
        isCurrentTransferDirectory = isDirectory
        currentFileName = isDirectory ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent

        defer {
            isTransferring = false
            currentFileName = nil
            isCurrentTransferDirectory = false
        }

        let data = try Data(contentsOf: url)
        let hash = HashVerifier.sha256(data)
        let fileName = url.lastPathComponent
        let fileSize = Int64(data.count)

        let metadata = TransferMetadata(
            fileName: fileName,
            fileSize: fileSize,
            mimeType: nil,
            sha256Hash: hash,
            isDirectory: isDirectory
        )

        // Send file offer
        let offer = try PeerMessage.fileOffer(metadata: metadata, senderID: "local")
        try await manager.sendMessage(offer)

        // Wait for accept/reject is handled by the message loop calling handleFileAccept/Reject

        // Send chunks
        let chunks = data.chunks(ofSize: chunkSize)
        for (index, chunk) in chunks.enumerated() {
            guard !isCancelled else { throw FileTransferError.cancelled }
            let chunkMsg = PeerMessage.fileChunk(chunk, senderID: "local")
            try await manager.sendMessage(chunkMsg)
            progress = Double(index + 1) / Double(chunks.count)
        }

        // Send completion
        let complete = try PeerMessage.fileComplete(hash: hash, senderID: "local")
        try await manager.sendMessage(complete)
        progress = 1.0

        let record = TransferRecord(
            fileName: fileName,
            fileSize: fileSize,
            direction: .sent,
            timestamp: Date(),
            success: true
        )
        manager.transferHistory.insert(record, at: 0)
        manager.latestToast = record
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
        currentFileName = metadata.displayName
        isCurrentTransferDirectory = metadata.isDirectory

        // Auto-accept for now (consent already given at connection level)
        Task {
            let accept = PeerMessage.fileAccept(senderID: "local")
            try? await connectionManager?.sendMessage(accept)
            isTransferring = true
            progress = 0
            connectionManager?.showTransferProgress = true
        }
    }

    /// Cancel an in-progress transfer without disconnecting.
    func cancelTransfer() {
        isCancelled = true
        isTransferring = false
        currentFileName = nil
        isCurrentTransferDirectory = false
        receiveBuffer = Data()
        receiveMetadata = nil
        lastError = "Transfer cancelled"
        connectionManager?.showTransferProgress = false
        connectionManager?.transition(to: .connected)
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
        let success = computedHash == metadata.sha256Hash

        if success {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(metadata.fileName)
            try? receiveBuffer.write(to: tempURL)

            // If the file is a zipped directory, unzip it
            if metadata.isDirectory {
                if let unzippedURL = try? tempURL.unzipFile() {
                    receivedFileURL = unzippedURL
                    // Clean up the intermediate zip
                    try? FileManager.default.removeItem(at: tempURL)
                } else {
                    // Fallback: present the zip if unzip fails
                    receivedFileURL = tempURL
                }
            } else {
                receivedFileURL = tempURL
            }

            lastError = nil
            HapticManager.transferComplete()
        } else {
            lastError = "Hash verification failed"
            HapticManager.transferFailed()
        }

        let record = TransferRecord(
            fileName: metadata.displayName,
            fileSize: metadata.fileSize,
            direction: .received,
            timestamp: Date(),
            success: success
        )
        connectionManager?.transferHistory.insert(record, at: 0)
        connectionManager?.latestToast = record

        isTransferring = false
        currentFileName = nil
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
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to a peer"
        case .hashMismatch: return "File integrity check failed"
        case .transferRejected: return "File transfer was rejected"
        case .cancelled: return "Transfer cancelled"
        }
    }
}
