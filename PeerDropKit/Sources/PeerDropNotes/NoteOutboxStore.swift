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
///
/// Load contract (never lose queued notes):
/// - missing file: empty store.
/// - transient failure (Keychain unavailable, file unreadable): `isLoadFailed`;
///   saves are BLOCKED (the file on disk is untouched) until `reloadIfNeeded()`
///   succeeds. In-memory changes made meanwhile are merged on reload.
/// - corrupt file (bad format / auth failure / bad JSON): the file is renamed to
///   `outbox.enc.corrupt-<timestamp>` (never overwritten or deleted), the store
///   starts empty and `loadError`/`quarantinedCount` report it for the UI.
@MainActor
public final class NoteOutboxStore: ObservableObject {
    private static let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "NoteOutboxStore")

    @Published public private(set) var entries: [NoteOutboxEntry] = []
    /// Entries whose network await is in flight (UI should not allow removal).
    @Published public private(set) var sendingIDs: Set<UUID> = []
    /// Human-readable load/save problem for the UI; nil when healthy.
    @Published public private(set) var loadError: String?
    @Published public private(set) var quarantinedCount: Int = 0
    /// True while the last load failed transiently; saves are blocked.
    public private(set) var isLoadFailed = false
    /// Last save error (also set on a failed removal save, retried later).
    public private(set) var lastError: String?

    private let directory: URL
    private let encryptor: ChatDataEncryptor
    private let reader: ((URL) throws -> Data)?
    private var saveDirty = false

    /// `reader` is a test seam replacing `encryptor.readAndDecrypt`.
    public init(directory: URL? = nil, encryptor: ChatDataEncryptor = .shared, reader: ((URL) throws -> Data)? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(PeerDropPersistence.scopedKey("Notes"), isDirectory: true)
        self.encryptor = encryptor
        self.reader = reader
        load(merging: [])
    }

    private var fileURL: URL { directory.appendingPathComponent("outbox.enc") }

    public var all: [NoteOutboxEntry] { entries }

    public func entries(forContact contactID: UUID) -> [NoteOutboxEntry] {
        entries.filter { $0.contactID == contactID }
    }

    public func failedCount(forContact contactID: UUID? = nil) -> Int {
        entries.filter { $0.state == .failed && (contactID == nil || $0.contactID == contactID) }.count
    }

    public func isSending(_ id: UUID) -> Bool { sendingIDs.contains(id) }

    @discardableResult
    public func enqueue(contactID: UUID, accountId: String, expectedIdentityKey: Data, text: String, now: Date = Date()) -> NoteOutboxEntry {
        let entry = NoteOutboxEntry(contactID: contactID, accountId: accountId, expectedIdentityKey: expectedIdentityKey,
                                    text: text, createdAt: now)
        reloadIfNeeded()
        entries.append(entry)
        save()
        return entry
    }

    public func markFailed(id: UUID, reason: String) {
        update(id) { $0.state = .failed; $0.failReason = reason; $0.nextAttemptAt = nil }
    }

    /// Marks every still-queued entry of a contact failed (binding cancelled,
    /// contact forgotten, ...). Entries are kept, never deleted.
    public func failQueuedEntries(forContact contactID: UUID, reason: String) {
        for e in entries where e.contactID == contactID && e.state == .queued {
            markFailed(id: e.id, reason: reason)
        }
    }

    /// Persists the attempt BEFORE the network await so a kill mid-send is
    /// bounded by the attempt cap. `nextAttemptAt` is the tentative backoff.
    public func beginAttempt(id: UUID, nextAttemptAt: Date?) {
        sendingIDs.insert(id)
        update(id) { $0.attempts += 1; $0.nextAttemptAt = nextAttemptAt }
    }

    public func endSending(id: UUID) { sendingIDs.remove(id) }

    public func setAttemptState(id: UUID, attempts: Int, nextAttemptAt: Date?) {
        update(id) { $0.attempts = attempts; $0.nextAttemptAt = nextAttemptAt }
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
        sendingIDs.remove(id)
        guard entries.contains(where: { $0.id == id }) else { return }
        entries.removeAll { $0.id == id }
        save()
    }

    /// Retries a previously failed save (e.g. a removal after a successful send),
    /// so a sent note is not resurrected by the next launch.
    public func retrySaveIfNeeded() {
        if saveDirty { save() }
    }

    /// After a transient load failure, tries to load again; in-memory entries
    /// created meanwhile are merged in. No-op when the last load succeeded.
    public func reloadIfNeeded() {
        guard isLoadFailed else { return }
        load(merging: entries)
    }

    private func update(_ id: UUID, _ change: (inout NoteOutboxEntry) -> Void) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        let before = entries[i]
        change(&entries[i])
        if entries[i] != before { save() }
    }

    private func load(merging pending: [NoteOutboxEntry]) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            isLoadFailed = false; entries = pending; refreshQuarantineCount()
            if !pending.isEmpty { save() }
            return
        }
        let data: Data
        do {
            data = try reader.map { try $0(fileURL) } ?? encryptor.readAndDecrypt(from: fileURL)
        } catch {
            if Self.isTransient(error) { failTransient(error, keeping: pending); return }
            quarantine(error, keeping: pending); return
        }
        do {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            let loaded = try dec.decode([NoteOutboxEntry].self, from: data)
            let known = Set(loaded.map(\.id))
            entries = loaded + pending.filter { !known.contains($0.id) }
            isLoadFailed = false; loadError = nil
            refreshQuarantineCount()
            if !pending.isEmpty { save() }
        } catch {
            quarantine(error, keeping: pending)
        }
    }

    private static func isTransient(_ error: Error) -> Bool {
        if case ChatDataEncryptor.EncryptionError.keychainError = error { return true }
        // unreadable file (I/O), as opposed to unreadable CONTENT
        if let ns = error as NSError?, ns.domain == NSCocoaErrorDomain, ns.code != NSFileReadCorruptFileError { return true }
        return false
    }

    private func failTransient(_ error: Error, keeping pending: [NoteOutboxEntry]) {
        Self.logger.error("outbox load failed transiently: \(error.localizedDescription, privacy: .public)")
        isLoadFailed = true
        loadError = "待寄清單暫時無法讀取：\(error.localizedDescription)"
        entries = pending
    }

    private func quarantine(_ error: Error, keeping pending: [NoteOutboxEntry]) {
        Self.logger.error("outbox corrupt, quarantining: \(error.localizedDescription, privacy: .public)")
        var dest = directory.appendingPathComponent("outbox.enc.corrupt-\(Int(Date().timeIntervalSince1970))")
        var n = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = directory.appendingPathComponent("outbox.enc.corrupt-\(Int(Date().timeIntervalSince1970))-\(n)"); n += 1
        }
        do {
            try FileManager.default.moveItem(at: fileURL, to: dest)
            isLoadFailed = false
            loadError = "待寄清單檔案損毀，已另存備份"
            entries = pending
            refreshQuarantineCount()
            if !pending.isEmpty { save() }
        } catch {
            // Could not preserve the original: do NOT overwrite it.
            failTransient(error, keeping: pending)
        }
    }

    private func refreshQuarantineCount() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        quarantinedCount = names.filter { $0.hasPrefix("outbox.enc.corrupt-") }.count
    }

    private func save() {
        guard !isLoadFailed else { saveDirty = true; return }   // never clobber an unread file
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
            try encryptor.encryptAndWrite(try enc.encode(entries), to: fileURL)
            saveDirty = false
        } catch {
            Self.logger.error("outbox save failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
            saveDirty = true
        }
    }
}
