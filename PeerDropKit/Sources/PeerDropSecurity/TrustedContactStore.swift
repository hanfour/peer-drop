import Foundation
import Combine
import os.log

/// Why `TrustedContactStore.setRendezvousEnabled(for:_:)` refused.
public enum RendezvousOptInError: Error, Equatable {
    case unknownContact
    /// Not a verified binding (no account, pending claim, blocked, duplicated
    /// key or no device id) — see `TrustedContactStore.isRendezvousEligible`.
    case notBound
    /// Already `maxRendezvousContacts` contacts enabled.
    case limitExceeded
}

public final class TrustedContactStore: ObservableObject {

    private static let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "TrustedContactStore")

    @Published public private(set) var contacts: [TrustedContact] = []

    private let storageKey: String
    private let encryptor: ChatDataEncryptor
    private let directory: URL?
    private var pendingSave: DispatchWorkItem?

    /// Maximum number of key-rotation audit entries kept per contact.
    /// Older entries are dropped to bound on-disk size.
    private static let maxKeyHistoryEntries = 20

    public var all: [TrustedContact] { contacts }

    public var nonBlocked: [TrustedContact] {
        contacts.filter { !$0.isBlocked }
    }

    public init(
        storageKey: String = "trusted-contacts",
        directory: URL? = nil,
        encryptor: ChatDataEncryptor = .shared
    ) {
        self.storageKey = storageKey
        self.directory = directory
        self.encryptor = encryptor
        self.contacts = load()
    }

    // MARK: - CRUD

    /// An account maps to at most one contact, so adding a contact that carries
    /// an `accountId` clears that same `accountId` from every other contact.
    public func add(_ contact: TrustedContact) {
        // The opt-in is only ever set through `setRendezvousEnabled` (binding
        // rule + limit); an incoming contact cannot carry it in.
        var contact = contact
        contact.rendezvousEnabled = nil
        if let accountId = contact.accountId {
            for i in contacts.indices where contacts[i].accountId == accountId {
                contacts[i].accountId = nil
                contacts[i].rendezvousEnabled = nil
            }
        }
        contacts.append(contact)
        scheduleSave()
    }

    public func remove(_ id: UUID) {
        contacts.removeAll { $0.id == id }
        scheduleSave()
    }

    public func removeAll() {
        contacts.removeAll()
        let url = storageURL
        try? FileManager.default.removeItem(at: url)
    }

    /// Pure selector for the CLI `--prune` command: IDs of contacts whose
    /// last activity — `lastVerified`, falling back to `firstConnected` for
    /// contacts never re-verified — is older than `olderThanDays` before
    /// `now`. Deterministic (no `Date()` inside) so it's unit-testable.
    public static func staleContactIDs(
        in contacts: [TrustedContact],
        olderThanDays days: Int,
        now: Date = Date()
    ) -> [UUID] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        return contacts
            .filter { ($0.lastVerified ?? $0.firstConnected) < cutoff }
            .map(\.id)
    }

    public func find(byId id: UUID) -> TrustedContact? {
        contacts.first { $0.id == id }
    }

    public func find(byPublicKey publicKey: Data) -> TrustedContact? {
        contacts.first { $0.matchesKey(publicKey) }
    }

    public func find(byDeviceId deviceId: String) -> TrustedContact? {
        contacts.first { $0.deviceId == deviceId }
    }

    public func find(byMailboxId mailboxId: String) -> TrustedContact? {
        contacts.first { $0.mailboxId == mailboxId }
    }

    /// `accountId` must be the `AccountID.raw` string (the form stored on contacts).
    public func find(byAccountId accountId: String) -> TrustedContact? {
        contacts.first { $0.accountId == accountId }
    }

    // MARK: - Trust Management

    public func updateTrustLevel(for id: UUID, to level: TrustLevel) {
        guard let index = contacts.firstIndex(where: { $0.id == id }) else { return }
        contacts[index].trustLevel = level
        if level == .verified {
            contacts[index].lastVerified = Date()
        }
        scheduleSave()
    }

    public func setBlocked(_ id: UUID, blocked: Bool) {
        guard let index = contacts.firstIndex(where: { $0.id == id }) else { return }
        contacts[index].isBlocked = blocked
        // Ruling R-d: blocking drops the opt-in, so unblocking never resumes it silently.
        if blocked { contacts[index].rendezvousEnabled = nil }
        scheduleSave()
    }

    public func updateMailboxId(for id: UUID, mailboxId: String) {
        guard let index = contacts.firstIndex(where: { $0.id == id }) else { return }
        contacts[index].mailboxId = mailboxId
        scheduleSave()
    }

    public func updatePeerProtocolVersion(for id: UUID, to version: PeerVersion) {
        guard let index = contacts.firstIndex(where: { $0.id == id }) else { return }
        guard contacts[index].peerProtocolVersion != version else { return }
        contacts[index].peerProtocolVersion = version
        scheduleSave()
    }

    /// Bind (or unbind with `nil`) an account to a contact. An account maps to
    /// at most one contact, so the same `accountId` is cleared everywhere else.
    /// Any pending binding on this contact is dropped.
    public func setAccountBinding(for id: UUID, accountId: String?) {
        guard let index = contacts.firstIndex(where: { $0.id == id }) else { return }
        if let accountId {
            for i in contacts.indices where i != index && contacts[i].accountId == accountId {
                contacts[i].accountId = nil
                contacts[i].rendezvousEnabled = nil
            }
        }
        if accountId == nil || accountId != contacts[index].accountId {
            // The opt-in was given for one binding; unbinding or rebinding drops it.
            contacts[index].rendezvousEnabled = nil
        }
        contacts[index].accountId = accountId
        contacts[index].pendingAccountBinding = nil
        scheduleSave()
    }

    // MARK: - Rendezvous ("always connected") opt-in

    /// Hard cap on contacts with the opt-in (spec §10.1).
    public static let maxRendezvousContacts = 5

    /// Same rule as `FriendBinding.verifiedAccount`: the contact resolves
    /// uniquely by key and is not blocked, `accountId != nil` and no pending
    /// claim. Additionally the connection key (`deviceId`) must be known
    /// (spec §12.12) and unique among contacts, and the key must be a 32-byte
    /// agreement key.
    public static func isRendezvousEligible(_ c: TrustedContact, among all: [TrustedContact]) -> Bool {
        guard !c.isBlocked, c.accountId != nil, c.pendingAccountBinding == nil,
              let deviceId = c.deviceId, !deviceId.isEmpty,
              c.identityPublicKey.count == 32 else { return false }
        // The device id is the connection / chat key: it must also be unique
        // among contacts, or a rendezvous connection (keyed by it) could be
        // attributed to — or collide with — another contact (Task 5 I-3).
        return all.filter { $0.matchesKey(c.identityPublicKey) }.count == 1
            && all.filter { $0.deviceId == deviceId }.count == 1
    }

    /// Contacts whose opt-in is on AND who are eligible right now (ineligible
    /// ones, e.g. during a pending re-exchange, are suspended, not listed).
    public var rendezvousEnabledContacts: [TrustedContact] {
        contacts.filter { $0.isRendezvousEnabled && Self.isRendezvousEligible($0, among: contacts) }
    }

    /// Turn the opt-in on or off. Enabling requires eligibility and at most
    /// `maxRendezvousContacts` enabled contacts; violations throw (never a
    /// silent no-op). Disabling a known contact always succeeds and stores nil.
    public func setRendezvousEnabled(for id: UUID, _ enabled: Bool) throws {
        guard let index = contacts.firstIndex(where: { $0.id == id }) else {
            throw RendezvousOptInError.unknownContact
        }
        guard enabled else {
            guard contacts[index].rendezvousEnabled != nil else { return }
            contacts[index].rendezvousEnabled = nil
            scheduleSave()
            return
        }
        guard Self.isRendezvousEligible(contacts[index], among: contacts) else {
            throw RendezvousOptInError.notBound
        }
        if contacts[index].isRendezvousEnabled { return }
        let others = contacts.indices.filter { $0 != index && contacts[$0].isRendezvousEnabled }.count
        guard others < Self.maxRendezvousContacts else { throw RendezvousOptInError.limitExceeded }
        contacts[index].rendezvousEnabled = true
        scheduleSave()
    }

    public func setPendingBinding(for id: UUID, _ binding: PendingAccountBinding?) {
        guard let index = contacts.firstIndex(where: { $0.id == id }) else { return }
        contacts[index].pendingAccountBinding = binding
        scheduleSave()
    }

    /// Fills the device ID only when none is recorded yet.
    public func setDeviceId(for id: UUID, _ deviceId: String) {
        guard let index = contacts.firstIndex(where: { $0.id == id }) else { return }
        guard contacts[index].deviceId == nil else { return }
        contacts[index].deviceId = deviceId
        scheduleSave()
    }

    // MARK: - Key Change Detection

    public func detectKeyChange(contactId: UUID, newPublicKey: Data) -> Bool {
        guard let contact = find(byId: contactId) else { return false }
        return !contact.matchesKey(newPublicKey)
    }

    /// Rotate the identity key for a contact and append an audit-trail entry to
    /// `keyHistory`. The history is bounded; oldest entries are dropped.
    /// No history entry is recorded when the new key matches the current key.
    public func updatePublicKey(
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
        // A new identity key invalidates any account binding made for the old one.
        contacts[index].accountId = nil
        contacts[index].pendingAccountBinding = nil
        // Project E: a new key never inherits the "always connected" opt-in.
        contacts[index].rendezvousEnabled = nil
        contacts[index].trustLevel = trustLevel
        if trustLevel != .verified {
            contacts[index].lastVerified = nil
        }
        scheduleSave()
    }

    // MARK: - Persistence (Encrypted)

    private var storageURL: URL {
        let dir = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
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

    public func flushPendingSave() {
        pendingSave?.cancel()
        save()
    }
}
