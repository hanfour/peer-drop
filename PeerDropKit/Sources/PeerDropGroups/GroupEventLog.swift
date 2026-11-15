import Foundation
import os
import PeerDropSecurity

/// Stores encrypted group events as independently framed records in an append-only log.
/// Each record is a UInt32 big-endian length followed by an independently encrypted JSON `WireEvent`.
/// A frame that fails to decrypt or decode is skipped; a short or overlong tail is truncated to the last
/// complete frame. A corrupted length prefix mid-file therefore drops the frames after it, which server
/// replay recovers. File operations are serialized process-wide (one static lock) so duplicate checks and
/// tail repair stay consistent across instances; `load()` reads the whole file, so keep it off the main actor.
public final class GroupEventLog: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "GroupEventLog")
    private static let ioLock = NSLock()
    private static let lengthPrefixSize = 4

    public let url: URL
    public let encryptor: ChatDataEncryptor

    /// Creates an event log at the given file URL.
    public init(url: URL, encryptor: ChatDataEncryptor = .shared) {
        self.url = url
        self.encryptor = encryptor
    }

    /// Encrypts and appends an event unless its `eventId` is already present.
    public func append(_ event: WireEvent) throws {
        Self.ioLock.lock()
        defer { Self.ioLock.unlock() }

        let existing = try readLog(throwOnRepairFailure: true)
        guard !existing.events.contains(where: { $0.eventId == event.eventId }) else { return }

        let encrypted = try encryptor.encrypt(JSONEncoder().encode(event))
        guard encrypted.count <= UInt32.max else { throw EventLogError.recordTooLarge }

        var frame = Data(capacity: Self.lengthPrefixSize + encrypted.count)
        var length = UInt32(encrypted.count).bigEndian
        frame.append(Data(bytes: &length, count: Self.lengthPrefixSize))
        frame.append(encrypted)

        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw EventLogError.cannotCreateFile
            }
        }

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: frame)
    }

    /// Loads unique events in ascending `seq` order and truncates an incomplete tail.
    public func load() -> LoadResult {
        Self.ioLock.lock()
        defer { Self.ioLock.unlock() }

        do {
            return try readLog(throwOnRepairFailure: false)
        } catch {
            Self.logger.error("failed to read group event log: \(error.localizedDescription, privacy: .public)")
            return LoadResult(events: [], droppedTailBytes: 0)
        }
    }

    /// Returns the greatest loaded sequence number, or zero when the log is empty.
    public var lastSeq: Int {
        load().events.map(\.seq).max() ?? 0
    }

    private func readLog(throwOnRepairFailure: Bool) throws -> LoadResult {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return LoadResult(events: [], droppedTailBytes: 0)
        }
        guard !isDirectory.boolValue else { throw EventLogError.unreadableFile }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw EventLogError.unreadableFile
        }

        var byEventId: [String: WireEvent] = [:]
        var offset = data.startIndex
        var invalidTailAt: Data.Index?

        while offset < data.endIndex {
            guard data.endIndex - offset >= Self.lengthPrefixSize else {
                invalidTailAt = offset
                break
            }

            let lengthBytes = data[offset..<(offset + Self.lengthPrefixSize)]
            let length = Int(lengthBytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
            let frameStart = offset + Self.lengthPrefixSize
            guard data.endIndex - frameStart >= length else {
                invalidTailAt = offset
                break
            }

            let frame = Data(data[frameStart..<(frameStart + length)])
            offset = frameStart + length

            do {
                let decrypted = try encryptor.decrypt(frame)
                let event = try JSONDecoder().decode(WireEvent.self, from: decrypted)
                byEventId[event.eventId] = event
            } catch {
                Self.logger.error("skipping corrupt group event log frame")
            }
        }

        var droppedTailBytes = 0
        if let invalidTailAt {
            droppedTailBytes = data.endIndex - invalidTailAt
            let completeFrames = Data(data[data.startIndex..<invalidTailAt])
            do {
                try completeFrames.write(to: url, options: .atomic)
            } catch {
                Self.logger.error("failed to truncate group event log tail")
                if throwOnRepairFailure { throw EventLogError.cannotRepairTail }
            }
        }

        let events = byEventId.values.sorted {
            if $0.seq == $1.seq { return $0.eventId < $1.eventId }
            return $0.seq < $1.seq
        }
        return LoadResult(events: events, droppedTailBytes: droppedTailBytes)
    }

    /// The events loaded from disk and the number of incomplete tail bytes removed.
    public struct LoadResult: Sendable, Equatable {
        public let events: [WireEvent]
        public let droppedTailBytes: Int

        public init(events: [WireEvent], droppedTailBytes: Int) {
            self.events = events
            self.droppedTailBytes = droppedTailBytes
        }
    }

    /// Failures encountered while appending to or repairing a group event log.
    public enum EventLogError: Error, Equatable {
        case recordTooLarge
        case cannotCreateFile
        case unreadableFile
        case cannotRepairTail
    }
}
