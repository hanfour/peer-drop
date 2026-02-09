import Foundation

/// Manages chunked file transfer with back-pressure and hash verification.
/// Supports both legacy single-connection mode and multi-connection session pool.
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

    // MARK: - Session Pool (Multi-Connection Support)

    /// Active file transfer sessions, keyed by peerID.
    private var sessions: [String: FileTransferSession] = [:]

    /// Get or create a file transfer session for a peer.
    func session(for peerID: String) -> FileTransferSession {
        if let existing = sessions[peerID] {
            return existing
        }
        let session = FileTransferSession(peerID: peerID)
        session.sendMessage = { [weak self] message in
            try await self?.connectionManager?.sendMessage(message, to: peerID)
        }
        sessions[peerID] = session
        return session
    }

    /// Remove a session when peer disconnects.
    func removeSession(for peerID: String) {
        sessions[peerID]?.handleConnectionFailure()
        sessions.removeValue(forKey: peerID)
    }

    // MARK: - Legacy Single-Connection State

    // Receive state — stream to disk instead of buffering in RAM
    private var receiveFileHandle: FileHandle?
    private var receiveTempURL: URL?
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

    /// Send files to the focused peer (legacy API).
    func sendFiles(at urls: [URL], directoryFlags: [URL: Bool] = [:]) async throws {
        guard let peerID = connectionManager?.focusedPeerID else {
            throw FileTransferError.notConnected
        }
        try await sendFiles(at: urls, to: peerID, directoryFlags: directoryFlags)
    }

    /// Send files to a specific peer.
    func sendFiles(at urls: [URL], to peerID: String, directoryFlags: [URL: Bool] = [:]) async throws {
        let session = session(for: peerID)

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
            try await sendFile(at: url, to: peerID, isDirectory: isDirectory, session: session)
        }
    }

    /// Send a single file to a specific peer.
    func sendFile(at url: URL, to peerID: String, isDirectory: Bool = false, session: FileTransferSession? = nil) async throws {
        guard let manager = connectionManager else {
            throw FileTransferError.notConnected
        }

        _ = session ?? self.session(for: peerID)

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

        let fileName = url.lastPathComponent
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attrs[.size] as? Int64) ?? 0

        // Stream hash computation from disk
        let hash = try HashVerifier.sha256(fileAt: url, chunkSize: chunkSize)

        let metadata = TransferMetadata(
            fileName: fileName,
            fileSize: fileSize,
            mimeType: nil,
            sha256Hash: hash,
            isDirectory: isDirectory
        )

        // Send file offer
        let offer = try PeerMessage.fileOffer(metadata: metadata, senderID: manager.localIdentity.id)
        try await manager.sendMessage(offer, to: peerID)

        // Stream chunks from disk via FileHandle (constant memory usage)
        let handle = try FileHandle(forReadingFrom: url)
        defer { handle.closeFile() }

        let totalChunks = max(1, Int((fileSize + Int64(chunkSize) - 1) / Int64(chunkSize)))
        var chunkIndex = 0

        for chunk in FileChunkIterator(handle: handle, chunkSize: chunkSize, totalSize: fileSize) {
            guard !isCancelled else { throw FileTransferError.cancelled }
            let chunkMsg = PeerMessage.fileChunk(chunk, senderID: manager.localIdentity.id)
            try await manager.sendMessage(chunkMsg, to: peerID)
            chunkIndex += 1
            progress = Double(chunkIndex) / Double(totalChunks)
        }

        // Send completion
        let complete = try PeerMessage.fileComplete(hash: hash, senderID: manager.localIdentity.id)
        try await manager.sendMessage(complete, to: peerID)
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

    /// Send a single file (legacy API, uses focused peer).
    func sendFile(at url: URL, isDirectory: Bool = false) async throws {
        guard let manager = connectionManager else {
            throw FileTransferError.notConnected
        }

        // Try multi-connection mode first
        if let peerID = manager.focusedPeerID {
            try await sendFile(at: url, to: peerID, isDirectory: isDirectory)
            return
        }

        // Fall back to legacy single-connection mode
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

        let fileName = url.lastPathComponent
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attrs[.size] as? Int64) ?? 0

        // Stream hash computation from disk
        let hash = try HashVerifier.sha256(fileAt: url, chunkSize: chunkSize)

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

        // Stream chunks from disk via FileHandle (constant memory usage)
        let handle = try FileHandle(forReadingFrom: url)
        defer { handle.closeFile() }

        let totalChunks = max(1, Int((fileSize + Int64(chunkSize) - 1) / Int64(chunkSize)))
        var chunkIndex = 0

        for chunk in FileChunkIterator(handle: handle, chunkSize: chunkSize, totalSize: fileSize) {
            guard !isCancelled else { throw FileTransferError.cancelled }
            let chunkMsg = PeerMessage.fileChunk(chunk, senderID: "local")
            try await manager.sendMessage(chunkMsg)
            chunkIndex += 1
            progress = Double(chunkIndex) / Double(totalChunks)
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
        receiveHasher = HashVerifier()
        receivedBytes = 0
        currentFileName = metadata.displayName
        isCurrentTransferDirectory = metadata.isDirectory

        // Prepare a temp file for streaming chunks to disk
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "_" + metadata.fileName)
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        receiveTempURL = tempURL
        receiveFileHandle = try? FileHandle(forWritingTo: tempURL)

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
        cleanupReceiveState(error: "Transfer cancelled")
        connectionManager?.showTransferProgress = false
        connectionManager?.transition(to: .connected)
    }

    /// Called by ConnectionManager when the connection drops unexpectedly.
    func handleConnectionFailure() {
        cleanupReceiveState(error: "Connection lost during transfer")

        // Also clean up all sessions
        for (_, session) in sessions {
            session.handleConnectionFailure()
        }
        sessions.removeAll()
    }

    private func cleanupReceiveState(error: String) {
        isCancelled = true
        isTransferring = false
        currentFileName = nil
        isCurrentTransferDirectory = false
        receiveFileHandle?.closeFile()
        receiveFileHandle = nil
        if let tempURL = receiveTempURL {
            try? FileManager.default.removeItem(at: tempURL)
        }
        receiveTempURL = nil
        receiveMetadata = nil
        batchMetadata = nil
        batchReceivedURLs = []
        batchFilesCompleted = 0
        overallProgress = 0
        totalFileCount = 0
        currentFileIndex = 0
        lastError = error
    }

    func handleFileAccept() {
        // Sender can proceed — chunks are already being sent
    }

    func handleFileReject(reason: String? = nil) {
        isTransferring = false
        if reason == "featureDisabled" {
            lastError = "Peer has file transfer disabled"
        } else {
            lastError = "File transfer was rejected"
        }
    }

    func handleFileChunk(_ message: PeerMessage) {
        guard let data = message.payload, let metadata = receiveMetadata else { return }

        receiveFileHandle?.write(data)
        receiveHasher.update(with: data)
        receivedBytes += Int64(data.count)
        progress = Double(receivedBytes) / Double(metadata.fileSize)
    }

    func handleFileComplete(_ message: PeerMessage) {
        guard let metadata = receiveMetadata else { return }

        receiveFileHandle?.closeFile()
        receiveFileHandle = nil

        let computedHash = receiveHasher.finalize()
        let success = computedHash == metadata.sha256Hash

        if success, let tempURL = receiveTempURL {
            let destURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(metadata.fileName)
            try? FileManager.default.removeItem(at: destURL)
            try? FileManager.default.moveItem(at: tempURL, to: destURL)

            let finalURL: URL
            if metadata.isDirectory, let unzippedURL = try? destURL.unzipFile() {
                finalURL = unzippedURL
                try? FileManager.default.removeItem(at: destURL)
            } else {
                finalURL = destURL
            }

            if batchMetadata != nil {
                batchReceivedURLs.append(finalURL)
                batchFilesCompleted += 1
            } else {
                receivedFileURL = finalURL
            }

            lastError = nil
            HapticManager.transferComplete()
        } else {
            if let tempURL = receiveTempURL {
                try? FileManager.default.removeItem(at: tempURL)
            }
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

        receiveTempURL = nil
        receiveMetadata = nil

        if batchMetadata == nil {
            isTransferring = false
            currentFileName = nil
            isCurrentTransferDirectory = false

            Task {
                connectionManager?.showTransferProgress = false
                connectionManager?.transition(to: .connected)
            }
        } else {
            currentFileName = nil
            isCurrentTransferDirectory = false
            progress = 0
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
