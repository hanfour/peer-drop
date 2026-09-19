import Foundation
import os
import PeerDropSecurity

/// One encrypted file per note under `<directory>/inbox/<id>.enc` and
/// `<directory>/sent/<id>.enc`, plus `state.enc` for the sync cursor.
/// Poison files are skipped (and reported via `lastLoadError`), never fatal.
public final class NotesStorage {
    private static let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "NotesStorage")
    public let directory: URL
    public let encryptor: ChatDataEncryptor
    /// Reflects the outcome of the LAST `loadInbox()`/`loadSent()` call only —
    /// reset to nil at the start of every load, so a later clean load clears
    /// an earlier poison-file error rather than latching it forever.
    public private(set) var lastLoadError: String?

    private struct State: Codable { var lastSeenInboxId: String? }

    public init(directory: URL? = nil, encryptor: ChatDataEncryptor = .shared) {
        self.directory = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Notes", isDirectory: true)
        self.encryptor = encryptor
    }

    private func folder(_ direction: NoteDirection) -> URL {
        directory.appendingPathComponent(direction == .inbound ? "inbox" : "sent", isDirectory: true)
    }
    private func url(_ id: String, _ direction: NoteDirection) -> URL { folder(direction).appendingPathComponent("\(id).enc") }
    private var stateURL: URL { directory.appendingPathComponent("state.enc") }

    public func loadInbox() -> [NoteRecord] { load(.inbound) }
    public func loadSent() -> [NoteRecord] { load(.outbound) }

    private func load(_ direction: NoteDirection) -> [NoteRecord] {
        lastLoadError = nil
        let dir = folder(direction)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        var out: [NoteRecord] = []
        for name in names where name.hasSuffix(".enc") {
            do {
                let data = try encryptor.readAndDecrypt(from: dir.appendingPathComponent(name))
                out.append(try JSONDecoder().decode(NoteRecord.self, from: data))
            } catch {
                lastLoadError = "\(name): \(error.localizedDescription)"
                Self.logger.error("skipping unreadable note file \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return out
    }

    public func save(_ record: NoteRecord) throws {
        try FileManager.default.createDirectory(at: folder(record.direction), withIntermediateDirectories: true)
        try encryptor.encryptAndWrite(JSONEncoder().encode(record), to: url(record.id, record.direction))
    }

    public func remove(id: String, direction: NoteDirection) throws {
        let u = url(id, direction)
        if FileManager.default.fileExists(atPath: u.path) { try FileManager.default.removeItem(at: u) }
    }

    public var lastSeenInboxId: String? {
        get {
            guard let data = try? encryptor.readAndDecrypt(from: stateURL) else { return nil }
            return (try? JSONDecoder().decode(State.self, from: data))?.lastSeenInboxId
        }
        set {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try encryptor.encryptAndWrite(JSONEncoder().encode(State(lastSeenInboxId: newValue)), to: stateURL)
            } catch {
                Self.logger.error("could not persist notes sync cursor: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
