import Foundation
import os
import PeerDropSecurity

/// One note the user explicitly queued from a friend thread (design §10.10).
/// The text is only ever sent because the user pressed send; nothing else
/// ever creates an entry.
public struct NoteOutboxEntry: Codable, Equatable, Identifiable {
    public enum State: String, Codable { case queued, failed }

    public let id: UUID
    public let contactID: UUID
    /// The account the user bound the contact to at queue time. If the contact's
    /// current verified account differs at send time the entry fails (never re-targets).
    public let accountId: String
    public let expectedIdentityKey: Data
    public let text: String
    public var createdAt: Date
    public var attempts: Int
    public var state: State
    public var failReason: String?
    /// Earliest time the next automatic attempt may run (exponential backoff).
    public var nextAttemptAt: Date?

    public init(id: UUID = UUID(), contactID: UUID, accountId: String, expectedIdentityKey: Data, text: String,
                createdAt: Date = Date(), attempts: Int = 0, state: State = .queued,
                failReason: String? = nil, nextAttemptAt: Date? = nil) {
        self.id = id; self.contactID = contactID; self.accountId = accountId
        self.expectedIdentityKey = expectedIdentityKey; self.text = text; self.createdAt = createdAt
        self.attempts = attempts; self.state = state; self.failReason = failReason; self.nextAttemptAt = nextAttemptAt
    }
}

/// Encrypted whole-file outbox (`outbox.enc`). Every mutation rewrites the file.
/// A missing or corrupt file yields an empty store, never a crash.
@MainActor
public final class NoteOutboxStore: ObservableObject {
    private static let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "NoteOutboxStore")

    @Published public private(set) var entries: [NoteOutboxEntry] = []
    /// Set when the last load/save failed (surface-able, non-fatal).
    public private(set) var lastError: String?

    private let directory: URL
    private let encryptor: ChatDataEncryptor

    public init(directory: URL? = nil, encryptor: ChatDataEncryptor = .shared) {
        self.directory = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(PeerDropPersistence.scopedKey("Notes"), isDirectory: true)
        self.encryptor = encryptor
        load()
    }

    private var fileURL: URL { directory.appendingPathComponent("outbox.enc") }

    public var all: [NoteOutboxEntry] { entries }

    public func entries(forContact contactID: UUID) -> [NoteOutboxEntry] {
        entries.filter { $0.contactID == contactID }
    }

    public func failedCount(forContact contactID: UUID? = nil) -> Int {
        entries.filter { $0.state == .failed && (contactID == nil || $0.contactID == contactID) }.count
    }

    @discardableResult
    public func enqueue(contactID: UUID, accountId: String, expectedIdentityKey: Data, text: String, now: Date = Date()) -> NoteOutboxEntry {
        let entry = NoteOutboxEntry(contactID: contactID, accountId: accountId, expectedIdentityKey: expectedIdentityKey,
                                    text: text, createdAt: now)
        entries.append(entry)
        save()
        return entry
    }

    public func markFailed(id: UUID, reason: String) {
        update(id) { $0.state = .failed; $0.failReason = reason; $0.nextAttemptAt = nil }
    }

    /// Records one failed retryable attempt and schedules the next one.
    public func recordAttempt(id: UUID, nextAttemptAt: Date?) {
        update(id) { $0.attempts += 1; $0.nextAttemptAt = nextAttemptAt }
    }

    /// User-initiated retry: back to `queued` with a clean slate. `createdAt` is
    /// reset so the 24 h age limit counts from the explicit retry.
    public func retry(id: UUID, now: Date = Date()) {
        update(id) {
            guard $0.state == .failed else { return }
            $0.state = .queued; $0.attempts = 0; $0.failReason = nil; $0.nextAttemptAt = nil; $0.createdAt = now
        }
    }

    public func remove(id: UUID) {
        guard entries.contains(where: { $0.id == id }) else { return }
        entries.removeAll { $0.id == id }
        save()
    }

    private func update(_ id: UUID, _ change: (inout NoteOutboxEntry) -> Void) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        let before = entries[i]
        change(&entries[i])
        if entries[i] != before { save() }
    }

    private func load() {
        lastError = nil
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try encryptor.readAndDecrypt(from: fileURL)
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            entries = try dec.decode([NoteOutboxEntry].self, from: data)
        } catch {
            Self.logger.error("outbox unreadable, starting empty: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
            entries = []
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
            try encryptor.encryptAndWrite(try enc.encode(entries), to: fileURL)
        } catch {
            Self.logger.error("outbox save failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
    }
}
