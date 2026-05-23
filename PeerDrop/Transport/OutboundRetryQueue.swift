import Foundation

/// Persistent retry queue for outbound messages whose X3DH initiation
/// failed (typically because the responder's OPK list was empty). On
/// every retry tick, the queue's owner re-fetches the recipient's bundle
/// and attempts X3DH again. Wired into `ConnectionManager` in Task 5.3.
///
/// Persistence: all entries flushed to disk (`storageURL`, AES-GCM via
/// `ChatDataEncryptor.shared`) on every mutation. Survives app launches
/// so a `policy.opkRetryMaxAttempts`-sized retry budget can span days.
///
/// Concurrency: actor — single sequential mutator. Tests + ConnectionManager
/// both hit the same isolation boundary.
actor OutboundRetryQueue {

    struct Entry: Codable, Identifiable, Equatable {
        let id: UUID
        let recipientMailboxId: String
        /// Plaintext message bytes — encryption happens after X3DH succeeds.
        let payloadData: Data
        var attemptCount: Int
        var firstAttemptAt: Date

        init(
            id: UUID,
            recipientMailboxId: String,
            payloadData: Data,
            attemptCount: Int,
            firstAttemptAt: Date
        ) {
            self.id = id
            self.recipientMailboxId = recipientMailboxId
            self.payloadData = payloadData
            self.attemptCount = attemptCount
            self.firstAttemptAt = firstAttemptAt
        }
    }

    private let storageURL: URL
    private let encryptor: ChatDataEncryptor
    private var entries: [Entry] = []

    init(
        storageURL: URL,
        encryptor: ChatDataEncryptor = .shared
    ) async throws {
        self.storageURL = storageURL
        self.encryptor = encryptor
        try self.load()
    }

    // MARK: - Mutators

    func enqueue(_ entry: Entry) throws {
        entries.append(entry)
        try save()
    }

    func remove(id: UUID) throws {
        entries.removeAll { $0.id == id }
        try save()
    }

    func update(_ entry: Entry) throws {
        guard let idx = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[idx] = entry
        try save()
    }

    // MARK: - Read-only

    func all() -> [Entry] {
        entries
    }

    func count() -> Int {
        entries.count
    }

    // MARK: - Persistence

    private func load() throws {
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            entries = []
            return
        }
        let blob = try Data(contentsOf: storageURL)
        guard !blob.isEmpty else {
            entries = []
            return
        }
        let plaintext = try encryptor.decrypt(blob)
        entries = try JSONDecoder().decode([Entry].self, from: plaintext)
    }

    private func save() throws {
        let plaintext = try JSONEncoder().encode(entries)
        let blob = try encryptor.encrypt(plaintext)
        try blob.write(to: storageURL, options: .atomic)
    }
}
