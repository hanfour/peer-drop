import Foundation
import os

private let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "FileTransferSession")

/// Per-peer file transfer session that manages receiving state for a single connection.
@MainActor
final class FileTransferSession: ObservableObject {
    let peerID: String

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

    /// Callback to send messages through the connection.
    var sendMessage: ((PeerMessage) async throws -> Void)?

    /// Persistent directory for received files, visible in Files.app.
    static var receivedFilesDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("PeerDrop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Return a unique file URL in receivedFilesDirectory, appending " (N)" for duplicates.
    static func uniqueDestination(for fileName: String) -> URL {
        let dir = receivedFilesDirectory
        var destURL = dir.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: destURL.path) else { return destURL }

        let stem = destURL.deletingPathExtension().lastPathComponent
        let ext = destURL.pathExtension
        var counter = 1
        repeat {
            let newName = ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
            destURL = dir.appendingPathComponent(newName)
            counter += 1
        } while FileManager.default.fileExists(atPath: destURL.path)
        return destURL
    }

    private let chunkSize = Data.defaultChunkSize
    private var isCancelled = false

    // Receive state — stream to disk instead of buffering in RAM
    private var receiveFileHandle: FileHandle?
    private var receiveTempURL: URL?
    private var receiveMetadata: TransferMetadata?
    private var receiveHasher = HashVerifier()
    private var receivedBytes: Int64 = 0

    // Batch receive state
    private var batchMetadata: BatchMetadata?
    private var batchReceivedURLs: [URL] = []
    private var batchFilesCompleted: Int = 0

    // Resume state
    private(set) var lastInterruptedTransfer: InterruptedTransfer?
    private var pendingResumeOffset: Int64 = 0

    struct InterruptedTransfer {
        let fileName: String
        let fileSize: Int64
        let sha256Hash: String
        let receivedBytes: Int64
        let tempURL: URL
    }

    init(peerID: String) {
        self.peerID = peerID
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
        guard let sendMessage else {
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
        let offer = try PeerMessage.fileOffer(metadata: metadata, senderID: peerID)
        try await sendMessage(offer)

        // Stream chunks from disk via FileHandle (constant memory usage)
        let handle = try FileHandle(forReadingFrom: url)
        defer { handle.closeFile() }

        let totalChunks = max(1, Int((fileSize + Int64(chunkSize) - 1) / Int64(chunkSize)))
        var chunkIndex = 0

        for chunk in FileChunkIterator(handle: handle, chunkSize: chunkSize, totalSize: fileSize) {
            guard !isCancelled else { throw FileTransferError.cancelled }
            let chunkMsg = PeerMessage.fileChunk(chunk, senderID: peerID)
            try await sendMessage(chunkMsg)
            chunkIndex += 1
            progress = Double(chunkIndex) / Double(totalChunks)
        }

        // Send completion
        let complete = try PeerMessage.fileComplete(hash: hash, senderID: peerID)
        try await sendMessage(complete)
        progress = 1.0
    }

    // MARK: - Receiving

    func handleFileOffer(_ message: PeerMessage) {
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
                    let reject = PeerMessage.fileReject(senderID: peerID, reason: "insufficientStorage")
                    do {
                        try await sendMessage?(reject)
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
            let accept = PeerMessage.fileAccept(senderID: peerID)
            do {
                try await sendMessage?(accept)
                isTransferring = true
                progress = 0
            } catch {
                logger.error("Failed to send file accept: \(error.localizedDescription)")
                lastError = "Failed to accept file transfer"
                cleanupReceiveState(error: "Failed to accept file transfer")
            }
        }
    }

    func cancelTransfer() {
        cleanupReceiveState(error: "Transfer cancelled")
    }

    func handleConnectionFailure() {
        // Save interrupted transfer state for potential resume
        if isTransferring, let metadata = receiveMetadata, let tempURL = receiveTempURL {
            receiveFileHandle?.closeFile()
            receiveFileHandle = nil
            lastInterruptedTransfer = InterruptedTransfer(
                fileName: metadata.fileName,
                fileSize: metadata.fileSize,
                sha256Hash: metadata.sha256Hash,
                receivedBytes: receivedBytes,
                tempURL: tempURL
            )
            logger.info("Saved interrupted transfer: \(metadata.fileName) at \(self.receivedBytes)/\(metadata.fileSize) bytes")
        }
        isCancelled = true
        isTransferring = false
        currentFileName = nil
        isCurrentTransferDirectory = false
        receiveFileHandle = nil
        receiveTempURL = nil
        receiveMetadata = nil
        batchMetadata = nil
        batchReceivedURLs = []
        batchFilesCompleted = 0
        overallProgress = 0
        totalFileCount = 0
        currentFileIndex = 0
        lastError = "Connection lost during transfer"
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

    func handleFileComplete(_ message: PeerMessage) -> TransferRecord? {
        guard let metadata = receiveMetadata else { return nil }

        receiveFileHandle?.closeFile()
        receiveFileHandle = nil

        let computedHash = receiveHasher.finalize()
        let success = computedHash == metadata.sha256Hash

        var resultRecord: TransferRecord?

        if success, let tempURL = receiveTempURL {
            let destURL = Self.uniqueDestination(for: metadata.fileName)
            do {
                try FileManager.default.moveItem(at: tempURL, to: destURL)
            } catch {
                logger.error("Failed to finalize file transfer: \(error.localizedDescription)")
            }

            let finalURL: URL
            if metadata.isDirectory {
                do {
                    let unzippedURL = try destURL.unzipFile()
                    finalURL = unzippedURL
                    try? FileManager.default.removeItem(at: destURL)
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

        resultRecord = TransferRecord(
            fileName: metadata.displayName,
            fileSize: metadata.fileSize,
            direction: .received,
            timestamp: Date(),
            success: success
        )

        receiveTempURL = nil
        receiveMetadata = nil

        if batchMetadata == nil {
            isTransferring = false
            currentFileName = nil
            isCurrentTransferDirectory = false
        } else {
            currentFileName = nil
            isCurrentTransferDirectory = false
            progress = 0
        }

        return resultRecord
    }

    // MARK: - Resume Support

    /// Check if we can resume a previously interrupted transfer for a new file offer.
    func canResume(metadata: TransferMetadata) -> Bool {
        guard let interrupted = lastInterruptedTransfer else { return false }
        return interrupted.fileName == metadata.fileName
            && interrupted.fileSize == metadata.fileSize
            && interrupted.sha256Hash == metadata.sha256Hash
            && interrupted.receivedBytes > 0
            && FileManager.default.fileExists(atPath: interrupted.tempURL.path)
    }

    /// Handle an incoming resume request from the sender.
    func handleResumeRequest(_ payload: FileResumePayload, peerConnection: PeerConnection, senderID: String) {
        guard let interrupted = lastInterruptedTransfer,
              interrupted.fileName == payload.fileName,
              interrupted.sha256Hash == payload.sha256Hash,
              FileManager.default.fileExists(atPath: interrupted.tempURL.path) else {
            // Cannot resume — send rejection
            let ack = FileResumeAckPayload(accepted: false, resumeOffset: 0)
            if let msg = try? PeerMessage.fileResumeAck(ack, senderID: senderID) {
                Task { try? await peerConnection.sendMessage(msg) }
            }
            return
        }

        // Accept resume from the interrupted point
        let ack = FileResumeAckPayload(accepted: true, resumeOffset: interrupted.receivedBytes)
        if let msg = try? PeerMessage.fileResumeAck(ack, senderID: senderID) {
            Task { try? await peerConnection.sendMessage(msg) }
        }

        // Restore receive state
        receiveTempURL = interrupted.tempURL
        receivedBytes = interrupted.receivedBytes
        receiveMetadata = TransferMetadata(
            fileName: payload.fileName,
            fileSize: payload.fileSize,
            mimeType: nil,
            sha256Hash: payload.sha256Hash,
            resumeOffset: interrupted.receivedBytes
        )
        currentFileName = payload.fileName
        isTransferring = true
        isCancelled = false
        progress = Double(receivedBytes) / Double(payload.fileSize)

        // Restore hasher by feeding it the already-received partial data
        receiveHasher = HashVerifier()
        do {
            let readHandle = try FileHandle(forReadingFrom: interrupted.tempURL)
            defer { readHandle.closeFile() }
            while true {
                let chunk = readHandle.readData(ofLength: chunkSize)
                guard !chunk.isEmpty else { break }
                receiveHasher.update(with: chunk)
            }
        } catch {
            logger.error("Failed to restore hash state from partial file: \(error.localizedDescription)")
            lastError = "Failed to resume transfer"
            return
        }

        do {
            receiveFileHandle = try FileHandle(forWritingTo: interrupted.tempURL)
            receiveFileHandle?.seekToEndOfFile()
        } catch {
            logger.error("Failed to reopen temp file for resume: \(error.localizedDescription)")
            lastError = "Failed to resume transfer"
        }

        lastInterruptedTransfer = nil
    }

    /// Handle resume acknowledgment from the receiver.
    func handleResumeAck(_ payload: FileResumeAckPayload) {
        if payload.accepted {
            pendingResumeOffset = payload.resumeOffset
            logger.info("Resume accepted at offset \(payload.resumeOffset)")
        } else {
            pendingResumeOffset = 0
            logger.info("Resume rejected, will start from beginning")
        }
    }

    /// Send a file with resume support, skipping bytes up to resumeOffset.
    func sendFileWithResume(at url: URL, resumeOffset: Int64, isDirectory: Bool = false) async throws {
        guard let sendMessage else { throw FileTransferError.notConnected }

        isTransferring = true
        isCancelled = false
        lastError = nil
        isCurrentTransferDirectory = isDirectory
        currentFileName = url.lastPathComponent

        defer {
            isTransferring = false
            currentFileName = nil
            isCurrentTransferDirectory = false
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attrs[.size] as? Int64) ?? 0

        let handle = try FileHandle(forReadingFrom: url)
        defer { handle.closeFile() }

        // Seek past already-sent bytes
        handle.seek(toFileOffset: UInt64(resumeOffset))
        var sentBytes = resumeOffset

        progress = Double(resumeOffset) / Double(fileSize)

        while !isCancelled {
            let data = handle.readData(ofLength: chunkSize)
            guard !data.isEmpty else { break }
            let chunkMsg = PeerMessage.fileChunk(data, senderID: peerID)
            try await sendMessage(chunkMsg)
            sentBytes += Int64(data.count)
            progress = Double(sentBytes) / Double(fileSize)
        }

        guard !isCancelled else { throw FileTransferError.cancelled }

        let hash = try HashVerifier.sha256(fileAt: url, chunkSize: chunkSize)
        let complete = try PeerMessage.fileComplete(hash: hash, senderID: peerID)
        try await sendMessage(complete)
        progress = 1.0
    }

    func clearInterruptedTransfer() {
        if let interrupted = lastInterruptedTransfer {
            try? FileManager.default.removeItem(at: interrupted.tempURL)
        }
        lastInterruptedTransfer = nil
    }
}

