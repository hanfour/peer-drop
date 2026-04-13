import Foundation
import CryptoKit
import os.log

/// Manages local pre-key generation, rotation, and encrypted persistence.
/// Pre-keys are uploaded to the relay server so peers can initiate X3DH offline.
final class PreKeyStore {

    static let initialOneTimePreKeyCount = 100
    static let replenishThreshold = 25
    static let signedPreKeyRotationInterval: TimeInterval = 7 * 24 * 60 * 60 // 7 days

    private static let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "PreKeyStore")

    private let storageKey: String
    private let encryptor = ChatDataEncryptor.shared
    private let lock = NSLock()

    private var _currentSignedPreKey: SignedPreKey
    private var previousSignedPreKeys: [SignedPreKey] = []
    private var oneTimePreKeys: [UInt32: OneTimePreKey] = [:]
    private var nextOneTimePreKeyId: UInt32 = 0
    private var nextSignedPreKeyId: UInt32 = 1

    var currentSignedPreKey: SignedPreKey {
        lock.lock()
        defer { lock.unlock() }
        return _currentSignedPreKey
    }

    var availableOneTimePreKeyCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return oneTimePreKeys.count
    }

    init(storageKey: String = "prekey-store") {
        self.storageKey = storageKey

        if let state = Self.loadState(storageKey: storageKey, encryptor: ChatDataEncryptor.shared) {
            self._currentSignedPreKey = state.currentSignedPreKey.toSignedPreKey()
            self.previousSignedPreKeys = state.previousSignedPreKeys.map { $0.toSignedPreKey() }
            self.oneTimePreKeys = Dictionary(uniqueKeysWithValues:
                state.oneTimePreKeys.map { ($0.id, $0.toOneTimePreKey()) }
            )
            self.nextOneTimePreKeyId = state.nextOneTimePreKeyId
            self.nextSignedPreKeyId = state.nextSignedPreKeyId
        } else {
            // try! is acceptable here: init failure = unrecoverable (Keychain broken)
            self._currentSignedPreKey = try! SignedPreKey.generate(id: 0, signingKey: IdentityKeyManager.shared)
            let initialKeys = OneTimePreKey.generateBatch(startId: 0, count: Self.initialOneTimePreKeyCount)
            self.oneTimePreKeys = Dictionary(uniqueKeysWithValues: initialKeys.map { ($0.id, $0) })
            self.nextOneTimePreKeyId = UInt32(Self.initialOneTimePreKeyCount)
            self.nextSignedPreKeyId = 1
            scheduleSave()
        }
    }

    // MARK: - Pre-Key Bundle Generation

    func generatePreKeyBundle() -> PreKeyBundle {
        lock.lock()
        defer { lock.unlock() }
        return PreKeyBundle(
            identityKey: IdentityKeyManager.shared.publicKey.rawRepresentation,
            signingKey: IdentityKeyManager.shared.signingPublicKey.rawRepresentation,
            signedPreKey: _currentSignedPreKey.asPublic(),
            oneTimePreKeys: oneTimePreKeys.values.map { $0.asPublic() }.sorted { $0.id < $1.id }
        )
    }

    // MARK: - One-Time Pre-Key Management

    func consumeOneTimePreKey(id: UInt32) throws -> OneTimePreKey? {
        lock.lock()
        defer { lock.unlock() }
        guard let key = oneTimePreKeys.removeValue(forKey: id) else { return nil }
        scheduleSave()
        replenishOneTimePreKeysLocked()
        return key
    }

    func replenishOneTimePreKeysIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        replenishOneTimePreKeysLocked()
    }

    private func replenishOneTimePreKeysLocked() {
        guard oneTimePreKeys.count < Self.replenishThreshold else { return }
        let deficit = Self.initialOneTimePreKeyCount - oneTimePreKeys.count
        let newKeys = OneTimePreKey.generateBatch(startId: nextOneTimePreKeyId, count: deficit)
        for key in newKeys {
            oneTimePreKeys[key.id] = key
        }
        nextOneTimePreKeyId += UInt32(deficit)
        scheduleSave()
        Self.logger.info("Replenished \(deficit) one-time pre-keys (total: \(self.oneTimePreKeys.count))")
    }

    // MARK: - Signed Pre-Key Rotation

    func rotateSignedPreKeyIfNeeded(forceRotate: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        let age = Date().timeIntervalSince(_currentSignedPreKey.timestamp)
        guard forceRotate || age > Self.signedPreKeyRotationInterval else { return }

        // Generate new key BEFORE mutating state, so failure leaves state consistent
        guard let newKey = try? SignedPreKey.generate(id: nextSignedPreKeyId, signingKey: IdentityKeyManager.shared) else {
            Self.logger.error("Failed to generate new signed pre-key during rotation")
            return
        }

        previousSignedPreKeys.append(_currentSignedPreKey)
        if previousSignedPreKeys.count > 3 {
            previousSignedPreKeys.removeFirst(previousSignedPreKeys.count - 3)
        }

        _currentSignedPreKey = newKey
        nextSignedPreKeyId += 1
        scheduleSave()
        Self.logger.info("Rotated signed pre-key to id \(self._currentSignedPreKey.id)")
    }

    func signedPreKey(for id: UInt32) throws -> SignedPreKey? {
        lock.lock()
        defer { lock.unlock() }
        if _currentSignedPreKey.id == id { return _currentSignedPreKey }
        return previousSignedPreKeys.first { $0.id == id }
    }

    // MARK: - Persistence

    private struct PersistedState: Codable {
        let currentSignedPreKey: PersistedSignedPreKey
        let previousSignedPreKeys: [PersistedSignedPreKey]
        let oneTimePreKeys: [PersistedOneTimePreKey]
        let nextOneTimePreKeyId: UInt32
        let nextSignedPreKeyId: UInt32
    }

    private struct PersistedSignedPreKey: Codable {
        let id: UInt32
        let publicKey: Data
        let privateKey: Data
        let signature: Data
        let timestamp: Date

        init(from key: SignedPreKey) {
            self.id = key.id; self.publicKey = key.publicKey
            self.privateKey = key.privateKey; self.signature = key.signature
            self.timestamp = key.timestamp
        }

        func toSignedPreKey() -> SignedPreKey {
            SignedPreKey(id: id, publicKey: publicKey, privateKey: privateKey, signature: signature, timestamp: timestamp)
        }
    }

    private struct PersistedOneTimePreKey: Codable {
        let id: UInt32
        let publicKey: Data
        let privateKey: Data

        init(from key: OneTimePreKey) {
            self.id = key.id; self.publicKey = key.publicKey; self.privateKey = key.privateKey
        }

        func toOneTimePreKey() -> OneTimePreKey {
            OneTimePreKey(id: id, publicKey: publicKey, privateKey: privateKey)
        }
    }

    private var pendingSave: DispatchWorkItem?

    private func scheduleSave() {
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.save() }
        pendingSave = item
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    func flush() {
        pendingSave?.cancel()
        save()
    }

    private func save() {
        lock.lock()
        let state = PersistedState(
            currentSignedPreKey: PersistedSignedPreKey(from: _currentSignedPreKey),
            previousSignedPreKeys: previousSignedPreKeys.map { PersistedSignedPreKey(from: $0) },
            oneTimePreKeys: oneTimePreKeys.values.map { PersistedOneTimePreKey(from: $0) },
            nextOneTimePreKeyId: nextOneTimePreKeyId,
            nextSignedPreKeyId: nextSignedPreKeyId
        )
        lock.unlock()

        do {
            let data = try JSONEncoder().encode(state)
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Security", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("\(storageKey).enc")
            try encryptor.encryptAndWrite(data, to: url)
        } catch {
            Self.logger.error("Failed to save pre-keys: \(error.localizedDescription)")
        }
    }

    private static func loadState(storageKey: String, encryptor: ChatDataEncryptor) -> PersistedState? {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Security", isDirectory: true)
        let url = dir.appendingPathComponent("\(storageKey).enc")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try encryptor.readAndDecrypt(from: url)
            return try JSONDecoder().decode(PersistedState.self, from: data)
        } catch {
            logger.error("Failed to load pre-keys: \(error.localizedDescription)")
            return nil
        }
    }

    func deleteAll() {
        lock.lock()
        oneTimePreKeys.removeAll()
        previousSignedPreKeys.removeAll()
        lock.unlock()

        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Security", isDirectory: true)
        let url = dir.appendingPathComponent("\(storageKey).enc")
        try? FileManager.default.removeItem(at: url)
    }
}
