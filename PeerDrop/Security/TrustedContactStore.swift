import Foundation
import Combine
import os.log

final class TrustedContactStore: ObservableObject {

    private static let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "TrustedContactStore")

    @Published private(set) var contacts: [TrustedContact] = []

    private let storageKey: String
    private let encryptor = ChatDataEncryptor.shared
    private var pendingSave: DispatchWorkItem?

    /// Maximum number of key-rotation audit entries kept per contact.
    /// Older entries are dropped to bound on-disk size.
    private static let maxKeyHistoryEntries = 20

    var all: [TrustedContact] { contacts }

    var nonBlocked: [TrustedContact] {
        contacts.filter { !$0.isBlocked }
    }

    init(storageKey: String = "trusted-contacts") {
        self.storageKey = storageKey
        self.contacts = load()
    }

    // MARK: - CRUD

    func add(_ contact: TrustedContact) {
        contacts.append(contact)
        scheduleSave()
    }

    func remove(_ id: UUID) {
        contacts.removeAll { $0.id == id }
        scheduleSave()
    }

    func removeAll() {
        contacts.removeAll()
        let url = storageURL
        try? FileManager.default.removeItem(at: url)
    }

    func find(byId id: UUID) -> TrustedContact? {
        contacts.first { $0.id == id }
    }

    func find(byPublicKey publicKey: Data) -> TrustedContact? {
        contacts.first { $0.matchesKey(publicKey) }
    }

    func find(byDeviceId deviceId: String) -> TrustedContact? {
        contacts.first { $0.deviceId == deviceId }
    }

    func find(byMailboxId mailboxId: String) -> TrustedContact? {
        contacts.first { $0.mailboxId == mailboxId }
    }

    // MARK: - Trust Management

    func updateTrustLevel(for id: UUID, to level: TrustLevel) {
        guard let index = contacts.firstIndex(where: { $0.id == id }) else { return }
        contacts[index].trustLevel = level
        if level == .verified {
            contacts[index].lastVerified = Date()
        }
        scheduleSave()
    }

    func setBlocked(_ id: UUID, blocked: Bool) {
        guard let index = contacts.firstIndex(where: { $0.id == id }) else { return }
        contacts[index].isBlocked = blocked
        scheduleSave()
    }

    func updateMailboxId(for id: UUID, mailboxId: String) {
        guard let index = contacts.firstIndex(where: { $0.id == id }) else { return }
        contacts[index].mailboxId = mailboxId
        scheduleSave()
    }

    // MARK: - Key Change Detection

    func detectKeyChange(contactId: UUID, newPublicKey: Data) -> Bool {
        guard let contact = find(byId: contactId) else { return false }
        return !contact.matchesKey(newPublicKey)
    }

    /// Rotate the identity key for a contact and append an audit-trail entry to
    /// `keyHistory`. The history is bounded; oldest entries are dropped.
    /// No history entry is recorded when the new key matches the current key.
    func updatePublicKey(
        for id: UUID,
        newKey: Data,
        trustLevel: TrustLevel = .unknown,
        reason: KeyChangeReason
    ) {
        guard let index = contacts.firstIndex(where: { $0.id == id }) else { return }
        let oldKey = contacts[index].identityPublicKey
        // No-op rotation: still apply trust-level changes, but skip history.
        guard oldKey != newKey else {
            contacts[index].trustLevel = trustLevel
            if trustLevel != .verified {
                contacts[index].lastVerified = nil
            }
            scheduleSave()
            return
        }
        let record = KeyChangeRecord(
            oldKey: oldKey,
            newKey: newKey,
            changedAt: Date(),
            reason: reason
        )
        contacts[index].keyHistory.append(record)
        // Cap history to bound disk size.
        let overflow = contacts[index].keyHistory.count - Self.maxKeyHistoryEntries
        if overflow > 0 {
            contacts[index].keyHistory.removeFirst(overflow)
        }
        contacts[index].identityPublicKey = newKey
        contacts[index].trustLevel = trustLevel
        if trustLevel != .verified {
            contacts[index].lastVerified = nil
        }
        scheduleSave()
    }

    // MARK: - Persistence (Encrypted)

    private var storageURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Security", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(storageKey).enc")
    }

    private func load() -> [TrustedContact] {
        let url = storageURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try encryptor.readAndDecrypt(from: url)
            return try JSONDecoder().decode([TrustedContact].self, from: data)
        } catch {
            return []
        }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.save()
        }
        pendingSave = item
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(contacts)
            try encryptor.encryptAndWrite(data, to: storageURL)
        } catch {
            Self.logger.error("Failed to save trusted contacts: \(error.localizedDescription)")
        }
    }

    func flushPendingSave() {
        pendingSave?.cancel()
        save()
    }
}
