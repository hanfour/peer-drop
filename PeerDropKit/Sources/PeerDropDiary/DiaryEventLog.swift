import Foundation
import os
import PeerDropSecurity

/// One diary's append-only, encrypted event log (spec §3.5) —
/// `Documents/Diary/<diaryId>/events.log`. Framing is
/// `UInt32 BE length ‖ ChatDataEncryptor.encrypt(single-event JSON)`; each
/// record is encrypted independently (rather than the whole file at once)
/// so a single damaged frame doesn't take down every event around it.
///
/// `load()` folds frames by `seq` (a later frame for the same `seq` wins —
/// a resend can legitimately overwrite an earlier local copy) and skips a
/// "poison" frame — one whose length prefix is structurally fine but whose
/// bytes fail to decrypt or don't decode as a `DiaryEvent` — continuing to
/// read past it. An invalid/truncated tail (the declared length can't even
/// be read, or runs past the end of the file — e.g. a crash mid-`append`)
/// instead **truncates the file to the last complete frame boundary**
/// (spec §3.5, amended 2026-09-23: the server is the source of truth and an
/// unreadable tail can't be recovered locally, so it's discarded rather
/// than kept around to jam every future `append`) and reports how many
/// bytes were dropped.
///
/// `@unchecked Sendable`: the only stored state is an immutable `URL` and a
/// `ChatDataEncryptor` reference (itself internally lock-protected); there
/// is no mutable stored state on this type to race on. All I/O is
/// `nonisolated` — safe to call off the main actor. `load()` is O(events);
/// callers must not run it on `@MainActor` for a long-lived diary.
public final class DiaryEventLog: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "DiaryEventLog")
    private static let lengthPrefixSize = 4

    public let url: URL
    public let encryptor: ChatDataEncryptor

    public init(url: URL, encryptor: ChatDataEncryptor = .shared) {
        self.url = url
        self.encryptor = encryptor
    }

    /// Encrypts and appends one event, returning its `seq` back (so a
    /// caller that just built the event doesn't need a follow-up `load()`
    /// to learn what it already knows). Encodes with
    /// `.millisecondsSince1970` so `createdAt` (also how the worker sends
    /// it — see `DiaryClient`) round-trips exactly.
    @discardableResult
    public nonisolated func append(_ event: DiaryEvent) throws -> Int {
        let json = try Self.encoder.encode(event)
        let encrypted = try encryptor.encrypt(json)
        guard encrypted.count <= UInt32.max else { throw EventLogError.recordTooLarge }

        var frame = Data(capacity: Self.lengthPrefixSize + encrypted.count)
        var length = UInt32(encrypted.count).bigEndian
        frame.append(Data(bytes: &length, count: Self.lengthPrefixSize))
        frame.append(encrypted)

        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw EventLogError.cannotCreateFile
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: frame)
        return event.seq
    }

    /// All events currently on disk, deduped by `seq` (later frame in the
    /// file wins) and sorted by `seq`. Never throws — an unreadable or
    /// missing file simply yields an empty result (consistent with
    /// `NotesStorage.load`); a bad tail is truncated away as a side effect
    /// (see the type doc) rather than surfaced as an error.
    public nonisolated func load() -> LoadResult {
        guard let data = try? Data(contentsOf: url) else {
            return LoadResult(events: [], maxSeq: 0, skippedFrames: 0, truncatedBytes: 0)
        }

        var bySeq: [Int: DiaryEvent] = [:]
        var offset = data.startIndex
        var skippedFrames = 0
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
                let event = try Self.decoder.decode(DiaryEvent.self, from: decrypted)
                bySeq[event.seq] = event   // later frame for the same seq wins
            } catch {
                skippedFrames += 1
                Self.logger.error("skipping poison diary event frame: \(error.localizedDescription, privacy: .public)")
            }
        }

        var truncatedBytes = 0
        if let invalidTailAt {
            truncatedBytes = data.endIndex - invalidTailAt
            Self.truncate(url: url, to: Data(data[data.startIndex..<invalidTailAt]))
            Self.logger.error("truncated \(truncatedBytes) unreadable byte(s) off the tail of the diary event log")
        }

        let events = bySeq.values.sorted { $0.seq < $1.seq }
        return LoadResult(events: events, maxSeq: events.map(\.seq).max() ?? 0, skippedFrames: skippedFrames, truncatedBytes: truncatedBytes)
    }

    /// Best-effort — a failed truncation just means the next `load()` will
    /// find (and re-truncate) the same invalid tail; it is not a reason to
    /// make `load()` throw.
    private nonisolated static func truncate(url: URL, to bytes: Data) {
        do {
            try bytes.write(to: url, options: .atomic)
        } catch {
            logger.error("failed to truncate diary event log tail: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The result of `load()`: the deduped/sorted events, the highest `seq`
    /// among them (0 for an empty log), how many content-level "poison"
    /// frames were skipped, and how many bytes (0 if none) were truncated
    /// off an invalid/unreadable tail during this call.
    public struct LoadResult: Sendable, Equatable {
        public let events: [DiaryEvent]
        public let maxSeq: Int
        public let skippedFrames: Int
        public let truncatedBytes: Int

        public init(events: [DiaryEvent], maxSeq: Int, skippedFrames: Int, truncatedBytes: Int) {
            self.events = events
            self.maxSeq = maxSeq
            self.skippedFrames = skippedFrames
            self.truncatedBytes = truncatedBytes
        }
    }

    // MARK: - Codable configuration shared by append/load

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }()

    public enum EventLogError: Error, Equatable {
        case recordTooLarge
        case cannotCreateFile
    }
}
