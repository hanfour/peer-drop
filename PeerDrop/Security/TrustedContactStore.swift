import Foundation
import Combine
import os.log

final class TrustedContactStore: ObservableObject {

    private static let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "TrustedContactStore")

    @Published private(set) var contacts: [TrustedContact] = []

    private let storageKey: String
    private let encryptor = ChatDataEncryptor.shared
    private var pendingSave: DispatchWorkItem?

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

    // MARK: - Key Change Detection

    func detectKeyChange(contactId: UUID, newPublicKey: Data) -> Bool {
        guard let contact = find(byId: contactId) else { return false }
        return !contact.matchesKey(newPublicKey)
    }

    func updatePublicKey(for id: UUID, newKey: Data, trustLevel: TrustLevel = .unknown) {
        guard let index = contacts.firstIndex(where: { $0.id == id }) else { return }
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
