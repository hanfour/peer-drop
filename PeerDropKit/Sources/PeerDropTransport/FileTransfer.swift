import Foundation
import PeerDropProtocol
import PeerDropSecurity
import PeerDropPlatform
import os

private let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "FileTransfer")

/// Manages chunked file transfer with back-pressure and hash verification.
/// Supports both legacy single-connection mode and multi-connection session pool.
@MainActor
public final class FileTransfer: ObservableObject {
    @Published public private(set) var progress: Double = 0
    @Published public private(set) var isTransferring = false
    @Published public private(set) var lastError: String?
    @Published public private(set) var currentFileName: String?
    @Published public var receivedFileURL: URL?
    @Published public var receivedFileURLs: [URL] = []
    @Published public private(set) var currentFileIndex: Int = 0
    @Published public private(set) var totalFileCount: Int = 0
    @Published public private(set) var overallProgress: Double = 0
    @Published public private(set) var isCurrentTransferDirectory: Bool = false

    private weak var host: TransportHost?
    private let chunkSize = Data.defaultChunkSize
    private var isCancelled = false

    // MARK: - Session Pool (Multi-Connection Support)

    /// Active file transfer sessions, keyed by peerID.
    private var sessions: [String: FileTransferSession] = [:]

    /// Get or create a file transfer session for a peer.
    public func session(for peerID: String) -> FileTransferSession {
        if let existing = sessions[peerID] {
            return existing
        }
        let session = FileTransferSession(peerID: peerID)
        session.sendMessage = { [weak self] message in
            try await self?.host?.sendMessage(message, to: peerID)
        }
        sessions[peerID] = session
        return session
    }

    /// Remove a session when peer disconnects.
    public func removeSession(for peerID: String) {
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

    public init(host: TransportHost) {
        self.host = host
    }

    // MARK: - Sending

    /// Send files to the focused peer (legacy API).
    public func sendFiles(at urls: [URL], directoryFlags: [URL: Bool] = [:]) async throws {
        guard let peerID = host?.focusedPeerID else {
            throw FileTransferError.notConnected
        }
        try await sendFiles(at: urls, to: peerID, directoryFlags: directoryFlags)
    }

    /// Send files to a specific peer.
    public func sendFiles(at urls: [URL], to peerID: String, directoryFlags: [URL: Bool] = [:]) async throws {
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
    public func sendFile(at url: URL, to peerID: String, isDirectory: Bool = false, session: FileTransferSession? = nil) async throws {
        guard let host = host else {
            throw FileTransferError.notConnected
        }

        // audit-#14 Stage 3: untrusted peer must not be a transfer target.
        // Surfaces as FileTransferError.peerNotTrusted at the caller — the
        // existing transfer-error UI path renders the localized description.
        guard host.isPeerTrustedForUserActions(peerID: peerID) else {
            throw FileTransferError.peerNotTrusted
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
        let offer = try PeerMessage.fileOffer(metadata: metadata, senderID: host.localPeerID)
        try await host.sendMessage(offer, to: peerID)

        // Stream chunks from disk via FileHandle (constant memory usage)
        let handle = try FileHandle(forReadingFrom: url)
        defer { handle.closeFile() }

        let totalChunks = max(1, Int((fileSize + Int64(chunkSize) - 1) / Int64(chunkSize)))
        var chunkIndex = 0

        for chunk in FileChunkIterator(handle: handle, chunkSize: chunkSize, totalSize: fileSize) {
            guard !isCancelled else { throw FileTransferError.cancelled }
            let chunkMsg = PeerMessage.fileChunk(chunk, senderID: host.localPeerID)
            try await host.sendMessage(chunkMsg, to: peerID)
            chunkIndex += 1
            progress = Double(chunkIndex) / Double(totalChunks)
        }

        // Send completion
        let complete = try PeerMessage.fileComplete(hash: hash, senderID: host.localPeerID)
        try await host.sendMessage(complete, to: peerID)
        progress = 1.0

        let record = TransferRecord(
            fileName: fileName,
            fileSize: fileSize,
            direction: .sent,
            timestamp: Date(),
            success: true
        )
        host.recordTransfer(record)
    }

    /// Send a single file (legacy API, uses focused peer).
    public func sendFile(at url: URL, isDirectory: Bool = false) async throws {
        guard let host = host else {
            throw FileTransferError.notConnected
        }

        // Try multi-connection mode first
        if let peerID = host.focusedPeerID {
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
        try await host.sendMessage(offer)

        // Stream chunks from disk via FileHandle (constant memory usage)
        let handle = try FileHandle(forReadingFrom: url)
        defer { handle.closeFile() }

        let totalChunks = max(1, Int((fileSize + Int64(chunkSize) - 1) / Int64(chunkSize)))
        var chunkIndex = 0

        for chunk in FileChunkIterator(handle: handle, chunkSize: chunkSize, totalSize: fileSize) {
            guard !isCancelled else { throw FileTransferError.cancelled }
            let chunkMsg = PeerMessage.fileChunk(chunk, senderID: "local")
            try await host.sendMessage(chunkMsg)
            chunkIndex += 1
            progress = Double(chunkIndex) / Double(totalChunks)
        }

        // Send completion
        let complete = try PeerMessage.fileComplete(hash: hash, senderID: "local")
        try await host.sendMessage(complete)
        progress = 1.0

        let record = TransferRecord(
            fileName: fileName,
            fileSize: fileSize,
            direction: .sent,
            timestamp: Date(),
            success: true
        )
        host.recordTransfer(record)
    }

    // MARK: - Receiving (called from ConnectionManager message loop)

    public func handleFileOffer(_ message: PeerMessage) {
        guard let payload = message.payload else {
            logger.error("File offer has no payload")
            lastError = "Invalid file offer received"
            return
        }

        let metadata: TransferMetadata
        do {
            metadata = try JSONDecoder().decode(TransferMetadata.self, from: payload)
        } catch {
            logger.error("Failed to decode file offer metadata: \(error.localizedDescription)")
            lastError = "Invalid file offer format"
            return
        }

        // Check available disk space before accepting
        do {
            let availableBytes = try URL(fileURLWithPath: NSTemporaryDirectory())
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage ?? 0
            if availableBytes < metadata.fileSize + 10_000_000 { // 10MB buffer
                logger.error("Insufficient disk space: need \(metadata.fileSize) bytes, available \(availableBytes)")
                lastError = "Not enough storage space"
                Task {
                    let reject = PeerMessage.fileReject(senderID: "local", reason: "insufficientStorage")
                    do {
                        try await host?.sendMessage(reject)
                    } catch {
                        logger.error("Failed to send rejection: \(error.localizedDescription)")
                    }
                }
                return
            }
        } catch {
            logger.error("Failed to check disk space: \(error.localizedDescription)")
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

        do {
            receiveFileHandle = try FileHandle(forWritingTo: tempURL)
        } catch {
            logger.error("Failed to create file handle for receiving: \(error.localizedDescription)")
            lastError = "Cannot prepare file for receiving"
            return
        }

        // Auto-accept for now (consent already given at connection level)
        Task {
            let accept = PeerMessage.fileAccept(senderID: "local")
            do {
                try await host?.sendMessage(accept)
                isTransferring = true
                progress = 0
                host?.transferDidStart()
            } catch {
                logger.error("Failed to send file accept: \(error.localizedDescription)")
                lastError = "Failed to accept file transfer"
                cleanupReceiveState(error: "Failed to accept file transfer")
            }
        }
    }

    /// Cancel an in-progress transfer without disconnecting.
    public func cancelTransfer() {
        cleanupReceiveState(error: "Transfer cancelled")
        host?.transferDidEnd()
    }

    /// Called by ConnectionManager when the connection drops unexpectedly.
    public func handleConnectionFailure() {
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
            try? FileManager.default.removeItem(at: tempURL) // P2: temp cleanup, failure is acceptable
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

    public func handleFileAccept() {
        // Sender can proceed — chunks are already being sent
    }

    public func handleFileReject(reason: String? = nil) {
        isTransferring = false
        if reason == "featureDisabled" {
            lastError = "Peer has file transfer disabled"
        } else {
            lastError = "File transfer was rejected"
        }
    }

    public func handleFileChunk(_ message: PeerMessage) {
        guard let data = message.payload, let metadata = receiveMetadata else { return }

        receiveFileHandle?.write(data)
        receiveHasher.update(with: data)
        receivedBytes += Int64(data.count)
        progress = Double(receivedBytes) / Double(metadata.fileSize)
    }

    public func handleFileComplete(_ message: PeerMessage) {
        guard let metadata = receiveMetadata else { return }

        receiveFileHandle?.closeFile()
        receiveFileHandle = nil

        let computedHash = receiveHasher.finalize()
        let success = computedHash == metadata.sha256Hash

        if success, let tempURL = receiveTempURL {
            let destURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(metadata.fileName)
            do {
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.moveItem(at: tempURL, to: destURL)
            } catch {
                logger.error("Failed to finalize file transfer: \(error.localizedDescription)")
            }

            let finalURL: URL
            if metadata.isDirectory {
                do {
                    let unzippedURL = try destURL.unzipFile()
                    finalURL = unzippedURL
                    try? FileManager.default.removeItem(at: destURL) // P2: temp cleanup, failure is acceptable
                } catch {
                    logger.error("Failed to unzip: \(error.localizedDescription)")
                    finalURL = destURL
                }
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
                try? FileManager.default.removeItem(at: tempURL) // P2: temp cleanup, failure is acceptable
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
        host?.recordTransfer(record)

        receiveTempURL = nil
        receiveMetadata = nil

        if batchMetadata == nil {
            isTransferring = false
            currentFileName = nil
            isCurrentTransferDirectory = false

            Task {
                host?.transferDidEnd()
            }
        } else {
            currentFileName = nil
            isCurrentTransferDirectory = false
            progress = 0
        }
    }
}

public enum FileTransferError: Error, LocalizedError {
    case notConnected
    case hashMismatch
    case transferRejected
    case cancelled
    case peerNotTrusted

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to a peer"
        case .hashMismatch: return "File integrity check failed"
        case .transferRejected: return "File transfer was rejected"
        case .cancelled: return "Transfer cancelled"
        case .peerNotTrusted:
            return "This peer hasn't been verified yet. Approve the pairing prompt before sending files."
        }
    }
}
