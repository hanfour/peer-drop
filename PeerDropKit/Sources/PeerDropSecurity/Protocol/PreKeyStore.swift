import Foundation
import CryptoKit
import os.log

/// Manages local pre-key generation, rotation, and encrypted persistence.
/// Pre-keys are uploaded to the relay server so peers can initiate X3DH offline.
public final class PreKeyStore {

    public static let initialOneTimePreKeyCount = 100
    public static let replenishThreshold = 25
    public static let signedPreKeyRotationInterval: TimeInterval = 7 * 24 * 60 * 60 // 7 days

    private static let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "PreKeyStore")

    private let storageKey: String
    private let encryptor = ChatDataEncryptor.shared
    private let lock = NSLock()

    /// Injected by `PeerDropApp.onAppear` (and callers in the test suite).
    /// Retained for symmetry with `RemoteSessionManager.policyStore`. The
    /// background-safe value used by `saveSync` is `activePolicy` below.
    public var policyStore: SecurityPolicyStore?

    /// Plain-value snapshot of `policyStore.current`. `SecurityPolicyStore.current`
    /// is `@MainActor`-isolated, so `saveSync` (background `DispatchQueue`) can't
    /// read it directly. `PeerDropApp` subscribes to `policyStore.$current` and
    /// re-assigns `activePolicy` on every update so the latest worker-supplied
    /// policy reaches the prune path without restarting the app.
    public var activePolicy: SecurityPolicy?
    /// Injected by `PeerDropApp.onAppear`. Records `c4.consumed_opk_pruned`
    /// and `c4.consumed_opk_size` on every `saveSync`.
    public var cryptoMetrics: CryptoHardeningMetrics?

    private var _currentSignedPreKey: SignedPreKey
    private var previousSignedPreKeys: [SignedPreKey] = []
    private var oneTimePreKeys: [UInt32: OneTimePreKey] = [:]
    private var nextOneTimePreKeyId: UInt32 = 0
    private var nextSignedPreKeyId: UInt32 = 1
    /// Ids of one-time pre-keys that have been consumed, keyed by the Date they
    /// were consumed. Persisted so that a crash between in-memory removal and
    /// disk persist cannot expose a consumed OTP for replay on next launch.
    /// The timestamp enables the prune pass (Task 3.8 / C4) to evict entries
    /// older than `policy.consumedOPKPruneWindowDays` (default 90 days).
    private var consumedOneTimePreKeyIds: [UInt32: Date] = [:]

    public var currentSignedPreKey: SignedPreKey {
        lock.lock()
        defer { lock.unlock() }
        return _currentSignedPreKey
    }

    public var availableOneTimePreKeyCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return oneTimePreKeys.count
    }

    public init(storageKey: String = "prekey-store") {
        self.storageKey = storageKey

        if let state = Self.loadState(storageKey: storageKey, encryptor: ChatDataEncryptor.shared) {
            self._currentSignedPreKey = state.currentSignedPreKey.toSignedPreKey()
            self.previousSignedPreKeys = state.previousSignedPreKeys.map { $0.toSignedPreKey() }
            self.consumedOneTimePreKeyIds = state.consumedOneTimePreKeyIds ?? [:]
            var loaded = Dictionary(uniqueKeysWithValues:
                state.oneTimePreKeys.map { ($0.id, $0.toOneTimePreKey()) }
            )
            // Crash-recovery: if any persisted OTP id is also in the consumed
            // set, that means we crashed after marking the OTP consumed but
            // before its removal landed on disk. Drop those OTPs now so they
            // are never surfaced for reuse.
            let crashedConsumeIds = self.consumedOneTimePreKeyIds.keys.filter { loaded[$0] != nil }
            if !crashedConsumeIds.isEmpty {
                Self.logger.warning("Evicting \(crashedConsumeIds.count) OTP(s) on load (consumed but not removed before crash)")
                for id in crashedConsumeIds { loaded.removeValue(forKey: id) }
            }
            self.oneTimePreKeys = loaded
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

    public func generatePreKeyBundle() -> PreKeyBundle {
        lock.lock()
        let spkPublicKey = _currentSignedPreKey.publicKey
        let publicSignedPreKey = _currentSignedPreKey.asPublic()
        let oneTimePublicKeys = oneTimePreKeys.values.map { $0.asPublic() }.sorted { $0.id < $1.id }
        lock.unlock()

        let timestamp = UInt64(Date().timeIntervalSince1970)
        var timestampPayload = spkPublicKey
        timestampPayload.append(uint64BigEndian(timestamp))
        let timestampSignature = try? IdentityKeyManager.shared.sign(timestampPayload)

        return PreKeyBundle(
            identityKey: IdentityKeyManager.shared.publicKey.rawRepresentation,
            signingKey: IdentityKeyManager.shared.signingPublicKey.rawRepresentation,
            signedPreKey: publicSignedPreKey,
            oneTimePreKeys: oneTimePublicKeys,
            signedPreKeyTimestamp: timestamp,
            signedPreKeyTimestampSignature: timestampSignature
        )
    }

    /// Encodes a UInt64 as 8 big-endian bytes.
    private func uint64BigEndian(_ value: UInt64) -> Data {
        var be = value.bigEndian
        return Data(bytes: &be, count: 8)
    }

    // MARK: - One-Time Pre-Key Management

    public func consumeOneTimePreKey(id: UInt32) throws -> OneTimePreKey? {
        lock.lock()
        // Reject re-consumption attempts. This guards against:
        //  (a) replays of an old initial message after the OTP was consumed
        //  (b) crash-after-mark-consumed-before-evict races (load() drops these
        //      from oneTimePreKeys, but the consumed set still rejects them)
        if consumedOneTimePreKeyIds[id] != nil {
            lock.unlock()
            return nil
        }
        guard let key = oneTimePreKeys[id] else {
            lock.unlock()
            return nil
        }
        // Mark consumed FIRST so that even if the synchronous save below
        // crashes mid-write, the next launch sees the id in the consumed set
        // and won't surface this OTP for reuse.
        consumedOneTimePreKeyIds[id] = Date()
        oneTimePreKeys.removeValue(forKey: id)
        replenishOneTimePreKeysLocked()
        // Snapshot state under the lock; release before file I/O.
        let stateToSave = makePersistedStateLocked()
        lock.unlock()
        saveSync(state: stateToSave)
        return key
    }

    public func replenishOneTimePreKeysIfNeeded() {
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

    public func rotateSignedPreKeyIfNeeded(forceRotate: Bool = false) {
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

    public func signedPreKey(for id: UInt32) throws -> SignedPreKey? {
        lock.lock()
        defer { lock.unlock() }
        if _currentSignedPreKey.id == id { return _currentSignedPreKey }
        return previousSignedPreKeys.first { $0.id == id }
    }

    // MARK: - Persistence

    public struct PersistedState: Codable {
        public let currentSignedPreKey: PersistedSignedPreKey
        public let previousSignedPreKeys: [PersistedSignedPreKey]
        public let oneTimePreKeys: [PersistedOneTimePreKey]
        public let nextOneTimePreKeyId: UInt32
        public let nextSignedPreKeyId: UInt32
        /// Consumed OPK IDs mapped to the Date they were consumed.
        /// Optional for backward compatibility with v3.3-era stores (no consumed
        /// set) and v5.0–v5.3 stores (array of UInt32). Manual Codable conformance
        /// handles all three formats transparently.
        public let consumedOneTimePreKeyIds: [UInt32: Date]?

        public enum CodingKeys: String, CodingKey {
            case currentSignedPreKey
            case previousSignedPreKeys
            case oneTimePreKeys
            case nextOneTimePreKeyId
            case nextSignedPreKeyId
            case consumedOneTimePreKeyIds
        }

        public init(
            currentSignedPreKey: PersistedSignedPreKey,
            previousSignedPreKeys: [PersistedSignedPreKey],
            oneTimePreKeys: [PersistedOneTimePreKey],
            nextOneTimePreKeyId: UInt32,
            nextSignedPreKeyId: UInt32,
            consumedOneTimePreKeyIds: [UInt32: Date]?
        ) {
            self.currentSignedPreKey = currentSignedPreKey
            self.previousSignedPreKeys = previousSignedPreKeys
            self.oneTimePreKeys = oneTimePreKeys
            self.nextOneTimePreKeyId = nextOneTimePreKeyId
            self.nextSignedPreKeyId = nextSignedPreKeyId
            self.consumedOneTimePreKeyIds = consumedOneTimePreKeyIds
        }

        // MARK: Decodable — backward-compat across three on-disk formats:
        //   v3.3-era:  consumedOneTimePreKeyIds absent (nil)
        //   v5.0–v5.3: consumedOneTimePreKeyIds is a JSON array of UInt32
        //   v5.4+:     consumedOneTimePreKeyIds is a flat JSON array of
        //              alternating UInt32 keys + ISO8601 Date values — Swift's
        //              default Codable encoding for `[UInt32: Date]`. Interop
        //              with non-Swift tools would require manual canonicalization.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.currentSignedPreKey = try c.decode(PersistedSignedPreKey.self, forKey: .currentSignedPreKey)
            self.previousSignedPreKeys = try c.decodeIfPresent([PersistedSignedPreKey].self, forKey: .previousSignedPreKeys) ?? []
            self.oneTimePreKeys = try c.decodeIfPresent([PersistedOneTimePreKey].self, forKey: .oneTimePreKeys) ?? []
            self.nextOneTimePreKeyId = try c.decode(UInt32.self, forKey: .nextOneTimePreKeyId)
            self.nextSignedPreKeyId = try c.decodeIfPresent(UInt32.self, forKey: .nextSignedPreKeyId) ?? 1

            // Three-way backward-compat decode for consumedOneTimePreKeyIds:
            if let asDict = try? c.decode([UInt32: Date].self, forKey: .consumedOneTimePreKeyIds) {
                // v5.4+ format: JSON object {"42": "2026-05-23T08:00:00Z", ...}
                self.consumedOneTimePreKeyIds = asDict
            } else if let asArray = try? c.decode([UInt32].self, forKey: .consumedOneTimePreKeyIds) {
                // v5.0–v5.3 format: JSON array [1, 2, 3]
                // Assign a fresh timestamp so the prune window starts from now.
                let now = Date()
                self.consumedOneTimePreKeyIds = Dictionary(uniqueKeysWithValues: asArray.map { ($0, now) })
            } else {
                // v3.3-era: field absent (nil treated as empty on load)
                self.consumedOneTimePreKeyIds = nil
            }
        }

        // MARK: Encodable — always write the v5.4+ format going forward.
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(currentSignedPreKey, forKey: .currentSignedPreKey)
            try c.encode(previousSignedPreKeys, forKey: .previousSignedPreKeys)
            try c.encode(oneTimePreKeys, forKey: .oneTimePreKeys)
            try c.encode(nextOneTimePreKeyId, forKey: .nextOneTimePreKeyId)
            try c.encode(nextSignedPreKeyId, forKey: .nextSignedPreKeyId)
            try c.encode(consumedOneTimePreKeyIds, forKey: .consumedOneTimePreKeyIds)
        }
    }

    public struct PersistedSignedPreKey: Codable {
        public let id: UInt32
        public let publicKey: Data
        public let privateKey: Data
        public let signature: Data
        public let timestamp: Date

        public init(from key: SignedPreKey) {
            self.id = key.id; self.publicKey = key.publicKey
            self.privateKey = key.privateKey; self.signature = key.signature
            self.timestamp = key.timestamp
        }

        public func toSignedPreKey() -> SignedPreKey {
            SignedPreKey(id: id, publicKey: publicKey, privateKey: privateKey, signature: signature, timestamp: timestamp)
        }
    }

    public struct PersistedOneTimePreKey: Codable {
        public let id: UInt32
        public let publicKey: Data
        public let privateKey: Data

        public init(from key: OneTimePreKey) {
            self.id = key.id; self.publicKey = key.publicKey; self.privateKey = key.privateKey
        }

        public func toOneTimePreKey() -> OneTimePreKey {
            OneTimePreKey(id: id, publicKey: publicKey, privateKey: privateKey)
        }
    }

    // MARK: - C4: Consumed-OPK Prune

    /// Drops consumed-OPK entries older than `policy.consumedOPKPruneWindowDays`.
    /// Mutates `state` in place. Returns the number of entries pruned (for telemetry).
    ///
    /// Safety: callers MUST enforce the cross-field invariant
    /// `policy.consumedOPKPruneWindowDays >= policy.spkMaxAgeDays * 4` (enforced
    /// globally by SecurityPolicy.validateInvariants() — see spec §4.4). Without
    /// the margin, an attacker could replay a bundle whose consumed-OPK record
    /// has been pruned while the SPK is still in the responder's previous-3 list.
    @discardableResult
    public static func pruneConsumedOPK(
        in state: inout PersistedState,
        now: Date,
        policy: SecurityPolicy
    ) -> Int {
        let cutoff = now.addingTimeInterval(-Double(policy.consumedOPKPruneWindowDays) * 86400)
        let before = state.consumedOneTimePreKeyIds?.count ?? 0
        // Keep only entries whose timestamp is within the prune window.
        let retained = state.consumedOneTimePreKeyIds?.filter { $0.value >= cutoff }
        state = PersistedState(
            currentSignedPreKey: state.currentSignedPreKey,
            previousSignedPreKeys: state.previousSignedPreKeys,
            oneTimePreKeys: state.oneTimePreKeys,
            nextOneTimePreKeyId: state.nextOneTimePreKeyId,
            nextSignedPreKeyId: state.nextSignedPreKeyId,
            consumedOneTimePreKeyIds: retained
        )
        let after = state.consumedOneTimePreKeyIds?.count ?? 0
        return before - after
    }

    // MARK: - Persistence (continued)

    private var pendingSave: DispatchWorkItem?

    private func scheduleSave() {
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.save() }
        pendingSave = item
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    public func flush() {
        pendingSave?.cancel()
        save()
    }

    /// Caller MUST hold `lock`. Builds an immutable snapshot for I/O outside
    /// the lock.
    private func makePersistedStateLocked() -> PersistedState {
        PersistedState(
            currentSignedPreKey: PersistedSignedPreKey(from: _currentSignedPreKey),
            previousSignedPreKeys: previousSignedPreKeys.map { PersistedSignedPreKey(from: $0) },
            oneTimePreKeys: oneTimePreKeys.values.map { PersistedOneTimePreKey(from: $0) },
            nextOneTimePreKeyId: nextOneTimePreKeyId,
            nextSignedPreKeyId: nextSignedPreKeyId,
            consumedOneTimePreKeyIds: consumedOneTimePreKeyIds
        )
    }

    /// Synchronous write. Lock MUST NOT be held while this runs — file I/O on
    /// the lock would serialise consumers behind disk latency.
    private func saveSync(state: PersistedState) {
        // C4 prune — drops consumed-OPK entries older than policy.consumedOPKPruneWindowDays.
        // No-op if no policy is available (e.g., in unit tests that don't inject one).
        var state = state
        if let policy = activePolicy {
            let pruned = Self.pruneConsumedOPK(in: &state, now: Date(), policy: policy)
            if pruned > 0 {
                cryptoMetrics?.record(.c4ConsumedOpkPruned)
            }
            cryptoMetrics?.record(.c4ConsumedOpkSize)
        }

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

    private func save() {
        lock.lock()
        let state = makePersistedStateLocked()
        lock.unlock()
        saveSync(state: state)
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

    public func deleteAll() {
        lock.lock()
        oneTimePreKeys.removeAll()
        previousSignedPreKeys.removeAll()
        consumedOneTimePreKeyIds.removeAll()
        lock.unlock()

        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Security", isDirectory: true)
        let url = dir.appendingPathComponent("\(storageKey).enc")
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Testing Support

#if DEBUG
    /// Returns a snapshot of the current persisted state for test assertions.
    /// Only available in DEBUG builds (i.e., unit tests).
    public func snapshotForTesting() -> PersistedState {
        lock.lock()
        defer { lock.unlock() }
        return makePersistedStateLocked()
    }

    /// Decodes a `PersistedState` from raw JSON — used by legacy-format tests.
    public static func decodeStateForTesting(from data: Data) throws -> PersistedState {
        return try JSONDecoder().decode(PersistedState.self, from: data)
    }

    /// Builds a minimal empty `PersistedState` for use in unit tests that exercise
    /// prune / serialisation logic without a full store. Uses a freshly generated
    /// signed pre-key so the Codable round-trip is always valid.
    public static func emptyStateForTesting() -> PersistedState {
        let spk = try! SignedPreKey.generate(id: 0, signingKey: IdentityKeyManager.shared)
        return PersistedState(
            currentSignedPreKey: PersistedSignedPreKey(from: spk),
            previousSignedPreKeys: [],
            oneTimePreKeys: [],
            nextOneTimePreKeyId: 0,
            nextSignedPreKeyId: 1,
            consumedOneTimePreKeyIds: [:]
        )
    }
#endif
}
