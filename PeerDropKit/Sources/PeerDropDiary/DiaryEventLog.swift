import Foundation
import os
import PeerDropSecurity

/// One diary's append-only, encrypted event log (spec §3.5) —
/// `Documents/Diary/<diaryId>/events.log`. Framing is
/// `UInt32 BE length ‖ ChatDataEncryptor.encrypt(single-event JSON)`; each
/// record is encrypted independently (rather than the whole file at once)
/// so a single damaged frame doesn't take down every event around it.
///
/// `load()` skips a "poison" frame — one whose declared length is
/// readable but that fails to decrypt or doesn't decode as a `DiaryEvent`
/// — and keeps reading past it. A *truncated tail* (the declared length
/// runs past the end of the file, e.g. a crash mid-`append`) instead stops
/// the read entirely, without discarding the events already parsed before
/// it.
///
/// All I/O here is `nonisolated` — safe to call off the main actor.
/// `load()` is O(events); callers must not run it on `@MainActor` for a
/// long-lived diary.
public final class DiaryEventLog {
    private static let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "DiaryEventLog")
    private static let lengthPrefixSize = 4

    public let url: URL
    public let encryptor: ChatDataEncryptor

    /// Reflects the outcome of the LAST `load()` call only — nil when every
    /// frame parsed cleanly, reset at the start of each `load()` so a later
    /// clean load clears an earlier error rather than latching it forever.
    public private(set) var lastLoadError: String?

    public init(url: URL, encryptor: ChatDataEncryptor = .shared) {
        self.url = url
        self.encryptor = encryptor
    }

    /// Encrypts and appends one event. Encodes with
    /// `.millisecondsSince1970` so `createdAt` (also how the worker sends
    /// it — see `DiaryClient`) round-trips exactly.
    public nonisolated func append(_ event: DiaryEvent) throws {
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
    }

    /// All events currently on disk, sorted by `seq`. Never throws — an
    /// unreadable or missing file simply yields an empty log (consistent
    /// with `NotesStorage.load`).
    public nonisolated func load() -> [DiaryEvent] {
        lastLoadError = nil
        guard let data = try? Data(contentsOf: url) else { return [] }

        var events: [DiaryEvent] = []
        var offset = data.startIndex
        var poisonCount = 0

        while offset < data.endIndex {
            guard data.endIndex - offset >= Self.lengthPrefixSize else {
                lastLoadError = "truncated length prefix at byte offset \(offset - data.startIndex)"
                break
            }
            let lengthBytes = data[offset..<(offset + Self.lengthPrefixSize)]
            let length = Int(lengthBytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
            let frameStart = offset + Self.lengthPrefixSize
            guard length >= 0, data.endIndex - frameStart >= length else {
                lastLoadError = "truncated frame at byte offset \(offset - data.startIndex) (declared \(length) bytes)"
                break
            }
            let frame = Data(data[frameStart..<(frameStart + length)])
            offset = frameStart + length

            do {
                let decrypted = try encryptor.decrypt(frame)
                let event = try Self.decoder.decode(DiaryEvent.self, from: decrypted)
                events.append(event)
            } catch {
                poisonCount += 1
                Self.logger.error("skipping poison diary event frame: \(error.localizedDescription, privacy: .public)")
            }
        }

        if poisonCount > 0 {
            let suffix = lastLoadError.map { " (\($0))" } ?? ""
            lastLoadError = "\(poisonCount) poison frame(s) skipped\(suffix)"
        }
        return events.sorted { $0.seq < $1.seq }
    }

    /// The highest `seq` currently on disk, or 0 for an empty/missing log.
    public nonisolated var maxSeq: Int {
        load().map(\.seq).max() ?? 0
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
