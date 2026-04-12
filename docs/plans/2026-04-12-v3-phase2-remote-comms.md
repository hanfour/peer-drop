# v3.0 Phase 2 — Remote Communication Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a complete encrypted remote communication system with X3DH key agreement, Double Ratchet forward secrecy, zero-knowledge Cloudflare Worker relay, and anonymous mailbox — enabling PeerDrop users to securely communicate when not on the same network.

**Architecture:** Self-contained Signal Protocol implementation using CryptoKit (no libsignal dependency). Client-side pre-key management generates signed pre-keys and one-time pre-keys stored in Keychain. Cloudflare Worker v2 API provides pre-key distribution, anonymous mailbox message relay with 7-day TTL, and Proof-of-Work anti-abuse. Double Ratchet provides per-message forward secrecy for remote sessions.

**Tech Stack:** CryptoKit (Curve25519 X3DH, AES-256-GCM, HKDF-SHA256), Cloudflare Workers + KV + Durable Objects, existing Phase 1 security layer (IdentityKeyManager, TrustedContactStore, SessionKeyManager).

**Design Doc:** `docs/plans/2026-04-12-v3-secure-comms-design.md` (Sections 3.3, 4, 5.3)

**Phase 1 Foundation (already built):**
- `PeerDrop/Security/IdentityKeyManager.swift` — Persistent Curve25519 identity keys
- `PeerDrop/Security/TrustedContactStore.swift` — Encrypted contacts with trust levels
- `PeerDrop/Security/SessionKeyManager.swift` — ECDH + AES-256-GCM
- `PeerDrop/Security/TrustedContact.swift` — Contact model (has `mailboxId` field reserved)
- `PeerDrop/Core/ConnectionManager.swift` — Connection lifecycle, relay flow
- `PeerDrop/Transport/WorkerSignaling.swift` — Current Cloudflare Worker client
- `cloudflare-worker/src/index.ts` — Current signaling server (POST /room, GET /room/:code WS, POST /room/:code/ice)

**Build/Test:**
- `xcodegen generate` after new .swift files
- Build: `xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet`
- Test: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest'`
- Worker: `cd cloudflare-worker && npx wrangler dev` (local), `npx wrangler deploy` (prod)

---

## Task 1: PreKeyBundle — Data Model for Pre-Key Packages

The pre-key bundle is what a peer uploads to the server so others can initiate X3DH key agreements with them, even when they're offline.

**Files:**
- Create: `PeerDrop/Security/Protocol/PreKeyBundle.swift`
- Create: `PeerDropTests/PreKeyBundleTests.swift`

**Step 1: Write the failing tests**

```swift
// PeerDropTests/PreKeyBundleTests.swift
import XCTest
import CryptoKit
@testable import PeerDrop

final class PreKeyBundleTests: XCTestCase {

    func testSignedPreKeyGeneration() {
        let signedPreKey = SignedPreKey.generate(
            id: 1,
            signingKey: IdentityKeyManager.shared
        )
        XCTAssertEqual(signedPreKey.id, 1)
        XCTAssertEqual(signedPreKey.publicKey.count, 32)
        XCTAssertFalse(signedPreKey.signature.isEmpty)
    }

    func testSignedPreKeyVerification() {
        let signedPreKey = SignedPreKey.generate(
            id: 1,
            signingKey: IdentityKeyManager.shared
        )
        let isValid = signedPreKey.verify(
            with: IdentityKeyManager.shared.signingPublicKey
        )
        XCTAssertTrue(isValid)
    }

    func testSignedPreKeyRejectsWrongSigner() {
        let signedPreKey = SignedPreKey.generate(
            id: 1,
            signingKey: IdentityKeyManager.shared
        )
        let otherSigningKey = Curve25519.Signing.PrivateKey()
        let isValid = signedPreKey.verify(with: otherSigningKey.publicKey)
        XCTAssertFalse(isValid)
    }

    func testOneTimePreKeyGeneration() {
        let keys = OneTimePreKey.generateBatch(startId: 0, count: 5)
        XCTAssertEqual(keys.count, 5)
        for (i, key) in keys.enumerated() {
            XCTAssertEqual(key.id, UInt32(i))
            XCTAssertEqual(key.publicKey.count, 32)
        }
    }

    func testPreKeyBundleCodable() throws {
        let signedPreKey = SignedPreKey.generate(id: 1, signingKey: IdentityKeyManager.shared)
        let oneTimeKeys = OneTimePreKey.generateBatch(startId: 0, count: 3)

        let bundle = PreKeyBundle(
            identityKey: IdentityKeyManager.shared.publicKey.rawRepresentation,
            signingKey: IdentityKeyManager.shared.signingPublicKey.rawRepresentation,
            signedPreKey: signedPreKey.asPublic(),
            oneTimePreKeys: oneTimeKeys.map { $0.asPublic() }
        )

        let data = try JSONEncoder().encode(bundle)
        let decoded = try JSONDecoder().decode(PreKeyBundle.self, from: data)

        XCTAssertEqual(decoded.identityKey, bundle.identityKey)
        XCTAssertEqual(decoded.signingKey, bundle.signingKey)
        XCTAssertEqual(decoded.signedPreKey.id, bundle.signedPreKey.id)
        XCTAssertEqual(decoded.oneTimePreKeys.count, 3)
    }

    func testPreKeyBundleWithoutOneTimeKeys() throws {
        let signedPreKey = SignedPreKey.generate(id: 1, signingKey: IdentityKeyManager.shared)
        let bundle = PreKeyBundle(
            identityKey: IdentityKeyManager.shared.publicKey.rawRepresentation,
            signingKey: IdentityKeyManager.shared.signingPublicKey.rawRepresentation,
            signedPreKey: signedPreKey.asPublic(),
            oneTimePreKeys: []
        )
        let data = try JSONEncoder().encode(bundle)
        let decoded = try JSONDecoder().decode(PreKeyBundle.self, from: data)
        XCTAssertTrue(decoded.oneTimePreKeys.isEmpty)
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/PreKeyBundleTests 2>&1 | tail -20`
Expected: FAIL — types not found

**Step 3: Write the implementation**

```swift
// PeerDrop/Security/Protocol/PreKeyBundle.swift
import Foundation
import CryptoKit

// MARK: - Signed Pre-Key

/// A medium-term key signed by the identity signing key.
/// Rotated every 7 days. Allows peers to initiate X3DH without us being online.
struct SignedPreKey {
    let id: UInt32
    let publicKey: Data                  // Curve25519 agreement public key
    let privateKey: Data                 // Curve25519 agreement private key (stored locally only)
    let signature: Data                  // Ed25519 signature of publicKey
    let timestamp: Date

    static func generate(id: UInt32, signingKey: IdentityKeyManager) -> SignedPreKey {
        let keyPair = Curve25519.KeyAgreement.PrivateKey()
        let pubKeyData = keyPair.publicKey.rawRepresentation
        let signature = try! signingKey.sign(pubKeyData)
        return SignedPreKey(
            id: id,
            publicKey: pubKeyData,
            privateKey: keyPair.rawRepresentation,
            signature: signature,
            timestamp: Date()
        )
    }

    func verify(with signingPublicKey: Curve25519.Signing.PublicKey) -> Bool {
        signingPublicKey.isValidSignature(signature, for: publicKey)
    }

    /// Public-only version for wire transmission (no private key)
    func asPublic() -> PublicSignedPreKey {
        PublicSignedPreKey(id: id, publicKey: publicKey, signature: signature, timestamp: timestamp)
    }

    /// Reconstruct private key for crypto operations
    func agreementPrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
    }
}

/// Wire-safe version of SignedPreKey (no private key)
struct PublicSignedPreKey: Codable {
    let id: UInt32
    let publicKey: Data
    let signature: Data
    let timestamp: Date

    func verify(with signingPublicKey: Curve25519.Signing.PublicKey) -> Bool {
        signingPublicKey.isValidSignature(signature, for: publicKey)
    }

    func agreementPublicKey() throws -> Curve25519.KeyAgreement.PublicKey {
        try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
    }
}

// MARK: - One-Time Pre-Key

/// A single-use key consumed during X3DH. Provides per-session uniqueness.
struct OneTimePreKey {
    let id: UInt32
    let publicKey: Data
    let privateKey: Data

    static func generate(id: UInt32) -> OneTimePreKey {
        let keyPair = Curve25519.KeyAgreement.PrivateKey()
        return OneTimePreKey(
            id: id,
            publicKey: keyPair.publicKey.rawRepresentation,
            privateKey: keyPair.rawRepresentation
        )
    }

    static func generateBatch(startId: UInt32, count: Int) -> [OneTimePreKey] {
        (0..<count).map { OneTimePreKey.generate(id: startId + UInt32($0)) }
    }

    func asPublic() -> PublicOneTimePreKey {
        PublicOneTimePreKey(id: id, publicKey: publicKey)
    }

    func agreementPrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
    }
}

/// Wire-safe version (no private key)
struct PublicOneTimePreKey: Codable {
    let id: UInt32
    let publicKey: Data

    func agreementPublicKey() throws -> Curve25519.KeyAgreement.PublicKey {
        try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
    }
}

// MARK: - Pre-Key Bundle (wire format)

/// The complete public key package uploaded to the pre-key server.
/// Peers fetch this to initiate X3DH key agreement.
struct PreKeyBundle: Codable {
    let identityKey: Data                    // Curve25519 identity public key
    let signingKey: Data                     // Ed25519 signing public key
    let signedPreKey: PublicSignedPreKey      // Medium-term key + signature
    let oneTimePreKeys: [PublicOneTimePreKey] // Single-use keys
}
```

**Step 4: Run tests**

Run: `xcodegen generate && xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/PreKeyBundleTests 2>&1 | tail -20`
Expected: ALL PASS

**Step 5: Commit**

```bash
git add PeerDrop/Security/Protocol/PreKeyBundle.swift PeerDropTests/PreKeyBundleTests.swift
git commit -m "feat: add PreKeyBundle, SignedPreKey, and OneTimePreKey models"
```

---

## Task 2: PreKeyStore — Local Pre-Key Management and Persistence

Manages generation, rotation, and encrypted storage of the device's pre-keys.

**Files:**
- Create: `PeerDrop/Security/Protocol/PreKeyStore.swift`
- Create: `PeerDropTests/PreKeyStoreTests.swift`

**Step 1: Write the failing tests**

```swift
// PeerDropTests/PreKeyStoreTests.swift
import XCTest
import CryptoKit
@testable import PeerDrop

final class PreKeyStoreTests: XCTestCase {

    var store: PreKeyStore!

    override func setUp() {
        super.setUp()
        store = PreKeyStore(storageKey: "test-prekeys-\(UUID().uuidString)")
    }

    override func tearDown() {
        store.deleteAll()
        super.tearDown()
    }

    func testInitialSignedPreKeyGeneration() {
        XCTAssertNotNil(store.currentSignedPreKey)
        XCTAssertEqual(store.currentSignedPreKey.publicKey.count, 32)
    }

    func testInitialOneTimePreKeysGeneration() {
        XCTAssertEqual(store.availableOneTimePreKeyCount, PreKeyStore.initialOneTimePreKeyCount)
    }

    func testConsumeOneTimePreKey() throws {
        let initialCount = store.availableOneTimePreKeyCount
        let consumed = try store.consumeOneTimePreKey(id: 0)
        XCTAssertNotNil(consumed)
        XCTAssertEqual(store.availableOneTimePreKeyCount, initialCount - 1)
    }

    func testConsumeNonExistentKeyReturnsNil() throws {
        let consumed = try store.consumeOneTimePreKey(id: 99999)
        XCTAssertNil(consumed)
    }

    func testReplenishOneTimePreKeys() {
        // Consume all keys
        for i in 0..<UInt32(PreKeyStore.initialOneTimePreKeyCount) {
            _ = try? store.consumeOneTimePreKey(id: i)
        }
        XCTAssertEqual(store.availableOneTimePreKeyCount, 0)

        store.replenishOneTimePreKeysIfNeeded()
        XCTAssertGreaterThan(store.availableOneTimePreKeyCount, 0)
    }

    func testGeneratePreKeyBundle() {
        let bundle = store.generatePreKeyBundle()
        XCTAssertEqual(bundle.identityKey.count, 32)
        XCTAssertEqual(bundle.signingKey.count, 32)
        XCTAssertFalse(bundle.signedPreKey.signature.isEmpty)
        XCTAssertEqual(bundle.oneTimePreKeys.count, PreKeyStore.initialOneTimePreKeyCount)
    }

    func testSignedPreKeyRotation() {
        let oldId = store.currentSignedPreKey.id
        store.rotateSignedPreKeyIfNeeded(forceRotate: true)
        let newId = store.currentSignedPreKey.id
        XCTAssertNotEqual(oldId, newId)
    }

    func testLookupSignedPreKeyById() throws {
        let currentId = store.currentSignedPreKey.id
        let found = try store.signedPreKey(for: currentId)
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.publicKey, store.currentSignedPreKey.publicKey)
    }

    func testPersistenceRoundTrip() {
        let key = "test-persist-prekeys-\(UUID().uuidString)"
        let store1 = PreKeyStore(storageKey: key)
        let bundle1 = store1.generatePreKeyBundle()
        store1.flush()

        let store2 = PreKeyStore(storageKey: key)
        let bundle2 = store2.generatePreKeyBundle()

        XCTAssertEqual(bundle1.signedPreKey.id, bundle2.signedPreKey.id)
        XCTAssertEqual(bundle1.signedPreKey.publicKey, bundle2.signedPreKey.publicKey)

        store1.deleteAll()
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/PreKeyStoreTests 2>&1 | tail -20`
Expected: FAIL

**Step 3: Write the implementation**

```swift
// PeerDrop/Security/Protocol/PreKeyStore.swift
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

    private(set) var currentSignedPreKey: SignedPreKey
    private var previousSignedPreKeys: [SignedPreKey] = []  // Keep old ones for pending sessions
    private var oneTimePreKeys: [UInt32: OneTimePreKey] = [:]
    private var nextOneTimePreKeyId: UInt32 = 0
    private var nextSignedPreKeyId: UInt32 = 1

    var availableOneTimePreKeyCount: Int { oneTimePreKeys.count }

    init(storageKey: String = "prekey-store") {
        self.storageKey = storageKey

        // Try to load persisted state
        if let state = Self.load(storageKey: storageKey, encryptor: ChatDataEncryptor.shared) {
            self.currentSignedPreKey = state.currentSignedPreKey
            self.previousSignedPreKeys = state.previousSignedPreKeys
            self.oneTimePreKeys = Dictionary(uniqueKeysWithValues: state.oneTimePreKeys.map { ($0.id, $0) })
            self.nextOneTimePreKeyId = state.nextOneTimePreKeyId
            self.nextSignedPreKeyId = state.nextSignedPreKeyId
        } else {
            // First launch — generate initial keys
            self.currentSignedPreKey = SignedPreKey.generate(id: 0, signingKey: IdentityKeyManager.shared)
            let initialKeys = OneTimePreKey.generateBatch(startId: 0, count: Self.initialOneTimePreKeyCount)
            self.oneTimePreKeys = Dictionary(uniqueKeysWithValues: initialKeys.map { ($0.id, $0) })
            self.nextOneTimePreKeyId = UInt32(Self.initialOneTimePreKeyCount)
            self.nextSignedPreKeyId = 1
            scheduleSave()
        }
    }

    // MARK: - Pre-Key Bundle Generation

    func generatePreKeyBundle() -> PreKeyBundle {
        PreKeyBundle(
            identityKey: IdentityKeyManager.shared.publicKey.rawRepresentation,
            signingKey: IdentityKeyManager.shared.signingPublicKey.rawRepresentation,
            signedPreKey: currentSignedPreKey.asPublic(),
            oneTimePreKeys: oneTimePreKeys.values.map { $0.asPublic() }.sorted { $0.id < $1.id }
        )
    }

    // MARK: - One-Time Pre-Key Management

    func consumeOneTimePreKey(id: UInt32) throws -> OneTimePreKey? {
        guard let key = oneTimePreKeys.removeValue(forKey: id) else { return nil }
        scheduleSave()
        return key
    }

    func replenishOneTimePreKeysIfNeeded() {
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
        let age = Date().timeIntervalSince(currentSignedPreKey.timestamp)
        guard forceRotate || age > Self.signedPreKeyRotationInterval else { return }

        previousSignedPreKeys.append(currentSignedPreKey)
        // Keep max 3 previous signed pre-keys for pending sessions
        if previousSignedPreKeys.count > 3 {
            previousSignedPreKeys.removeFirst(previousSignedPreKeys.count - 3)
        }

        currentSignedPreKey = SignedPreKey.generate(id: nextSignedPreKeyId, signingKey: IdentityKeyManager.shared)
        nextSignedPreKeyId += 1
        scheduleSave()
        Self.logger.info("Rotated signed pre-key to id \(self.currentSignedPreKey.id)")
    }

    func signedPreKey(for id: UInt32) throws -> SignedPreKey? {
        if currentSignedPreKey.id == id { return currentSignedPreKey }
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
        let state = PersistedState(
            currentSignedPreKey: PersistedSignedPreKey(from: currentSignedPreKey),
            previousSignedPreKeys: previousSignedPreKeys.map { PersistedSignedPreKey(from: $0) },
            oneTimePreKeys: oneTimePreKeys.values.map { PersistedOneTimePreKey(from: $0) },
            nextOneTimePreKeyId: nextOneTimePreKeyId,
            nextSignedPreKeyId: nextSignedPreKeyId
        )
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

    private static func load(storageKey: String, encryptor: ChatDataEncryptor) -> PersistedState? {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Security", isDirectory: true)
        let url = dir.appendingPathComponent("\(storageKey).enc")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try encryptor.readAndDecrypt(from: url)
            let state = try JSONDecoder().decode(PersistedState.self, from: data)
            // Reconstruct from persisted
            return PersistedState(
                currentSignedPreKey: state.currentSignedPreKey,
                previousSignedPreKeys: state.previousSignedPreKeys,
                oneTimePreKeys: state.oneTimePreKeys,
                nextOneTimePreKeyId: state.nextOneTimePreKeyId,
                nextSignedPreKeyId: state.nextSignedPreKeyId
            )
        } catch {
            logger.error("Failed to load pre-keys: \(error.localizedDescription)")
            return nil
        }
    }

    // Helper to reconstruct full state from persisted
    private static func load(storageKey: String, encryptor: ChatDataEncryptor) -> (
        currentSignedPreKey: SignedPreKey,
        previousSignedPreKeys: [SignedPreKey],
        oneTimePreKeys: [OneTimePreKey],
        nextOneTimePreKeyId: UInt32,
        nextSignedPreKeyId: UInt32
    )? {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Security", isDirectory: true)
        let url = dir.appendingPathComponent("\(storageKey).enc")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try encryptor.readAndDecrypt(from: url)
            let state = try JSONDecoder().decode(PersistedState.self, from: data)
            return (
                currentSignedPreKey: state.currentSignedPreKey.toSignedPreKey(),
                previousSignedPreKeys: state.previousSignedPreKeys.map { $0.toSignedPreKey() },
                oneTimePreKeys: state.oneTimePreKeys.map { $0.toOneTimePreKey() },
                nextOneTimePreKeyId: state.nextOneTimePreKeyId,
                nextSignedPreKeyId: state.nextSignedPreKeyId
            )
        } catch {
            logger.error("Failed to load pre-keys: \(error.localizedDescription)")
            return nil
        }
    }

    func deleteAll() {
        oneTimePreKeys.removeAll()
        previousSignedPreKeys.removeAll()
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Security", isDirectory: true)
        let url = dir.appendingPathComponent("\(storageKey).enc")
        try? FileManager.default.removeItem(at: url)
    }
}
```

Note: The `load` method has two overloads — the implementer should consolidate into a single method returning the tuple. The PersistedState version is for Codable decode, the tuple version is what the init uses.

**Step 4: Run tests**

Run: `xcodegen generate && xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/PreKeyStoreTests 2>&1 | tail -20`
Expected: ALL PASS

**Step 5: Commit**

```bash
git add PeerDrop/Security/Protocol/PreKeyStore.swift PeerDropTests/PreKeyStoreTests.swift
git commit -m "feat: add PreKeyStore with encrypted persistence and rotation"
```

---

## Task 3: X3DH — Extended Triple Diffie-Hellman Key Agreement

The core of Signal Protocol's initial key exchange. Allows Alice to establish an encrypted session with Bob, even if Bob is offline.

**Files:**
- Create: `PeerDrop/Security/Protocol/X3DH.swift`
- Create: `PeerDropTests/X3DHTests.swift`

**Step 1: Write the failing tests**

```swift
// PeerDropTests/X3DHTests.swift
import XCTest
import CryptoKit
@testable import PeerDrop

final class X3DHTests: XCTestCase {

    func testInitiatorAndResponderDeriveTheSameKey() throws {
        // Setup: Bob publishes a pre-key bundle
        let bobIdentity = Curve25519.KeyAgreement.PrivateKey()
        let bobSigning = Curve25519.Signing.PrivateKey()
        let bobSignedPreKey = Curve25519.KeyAgreement.PrivateKey()
        let bobOneTimePreKey = Curve25519.KeyAgreement.PrivateKey()

        let bobSignedPreKeyPub = bobSignedPreKey.publicKey
        let bobSignedPreKeySig = try bobSigning.signature(for: bobSignedPreKeyPub.rawRepresentation)

        // Alice initiates X3DH
        let aliceIdentity = Curve25519.KeyAgreement.PrivateKey()
        let aliceEphemeral = Curve25519.KeyAgreement.PrivateKey()

        let aliceResult = try X3DH.initiatorKeyAgreement(
            myIdentityKey: aliceIdentity,
            myEphemeralKey: aliceEphemeral,
            theirIdentityKey: bobIdentity.publicKey,
            theirSignedPreKey: bobSignedPreKeyPub,
            theirOneTimePreKey: bobOneTimePreKey.publicKey
        )

        // Bob responds to X3DH
        let bobResult = try X3DH.responderKeyAgreement(
            myIdentityKey: bobIdentity,
            mySignedPreKey: bobSignedPreKey,
            myOneTimePreKey: bobOneTimePreKey,
            theirIdentityKey: aliceIdentity.publicKey,
            theirEphemeralKey: aliceEphemeral.publicKey
        )

        XCTAssertEqual(aliceResult.rootKey, bobResult.rootKey)
        XCTAssertEqual(aliceResult.chainKey, bobResult.chainKey)
    }

    func testX3DHWithoutOneTimePreKey() throws {
        let bobIdentity = Curve25519.KeyAgreement.PrivateKey()
        let bobSignedPreKey = Curve25519.KeyAgreement.PrivateKey()
        let aliceIdentity = Curve25519.KeyAgreement.PrivateKey()
        let aliceEphemeral = Curve25519.KeyAgreement.PrivateKey()

        let aliceResult = try X3DH.initiatorKeyAgreement(
            myIdentityKey: aliceIdentity,
            myEphemeralKey: aliceEphemeral,
            theirIdentityKey: bobIdentity.publicKey,
            theirSignedPreKey: bobSignedPreKey.publicKey,
            theirOneTimePreKey: nil
        )

        let bobResult = try X3DH.responderKeyAgreement(
            myIdentityKey: bobIdentity,
            mySignedPreKey: bobSignedPreKey,
            myOneTimePreKey: nil,
            theirIdentityKey: aliceIdentity.publicKey,
            theirEphemeralKey: aliceEphemeral.publicKey
        )

        XCTAssertEqual(aliceResult.rootKey, bobResult.rootKey)
    }

    func testDifferentEphemeralKeysDifferentResults() throws {
        let bobIdentity = Curve25519.KeyAgreement.PrivateKey()
        let bobSignedPreKey = Curve25519.KeyAgreement.PrivateKey()
        let aliceIdentity = Curve25519.KeyAgreement.PrivateKey()

        let result1 = try X3DH.initiatorKeyAgreement(
            myIdentityKey: aliceIdentity,
            myEphemeralKey: Curve25519.KeyAgreement.PrivateKey(),
            theirIdentityKey: bobIdentity.publicKey,
            theirSignedPreKey: bobSignedPreKey.publicKey,
            theirOneTimePreKey: nil
        )
        let result2 = try X3DH.initiatorKeyAgreement(
            myIdentityKey: aliceIdentity,
            myEphemeralKey: Curve25519.KeyAgreement.PrivateKey(),
            theirIdentityKey: bobIdentity.publicKey,
            theirSignedPreKey: bobSignedPreKey.publicKey,
            theirOneTimePreKey: nil
        )

        XCTAssertNotEqual(result1.rootKey, result2.rootKey)
    }
}
```

**Step 2: Run tests to verify they fail**

**Step 3: Write the implementation**

```swift
// PeerDrop/Security/Protocol/X3DH.swift
import Foundation
import CryptoKit

/// X3DH (Extended Triple Diffie-Hellman) key agreement protocol.
/// Establishes a shared secret between two parties, even when one is offline.
/// Reference: https://signal.org/docs/specifications/x3dh/
enum X3DH {

    struct KeyAgreementResult {
        let rootKey: SymmetricKey       // For initializing the Double Ratchet root chain
        let chainKey: SymmetricKey      // For initializing the Double Ratchet sending chain
    }

    /// Alice (initiator) computes the shared secret using Bob's pre-key bundle.
    static func initiatorKeyAgreement(
        myIdentityKey: Curve25519.KeyAgreement.PrivateKey,      // IK_A
        myEphemeralKey: Curve25519.KeyAgreement.PrivateKey,      // EK_A
        theirIdentityKey: Curve25519.KeyAgreement.PublicKey,     // IK_B
        theirSignedPreKey: Curve25519.KeyAgreement.PublicKey,    // SPK_B
        theirOneTimePreKey: Curve25519.KeyAgreement.PublicKey?   // OPK_B (optional)
    ) throws -> KeyAgreementResult {
        // DH1 = DH(IK_A, SPK_B)
        let dh1 = try myIdentityKey.sharedSecretFromKeyAgreement(with: theirSignedPreKey)
        // DH2 = DH(EK_A, IK_B)
        let dh2 = try myEphemeralKey.sharedSecretFromKeyAgreement(with: theirIdentityKey)
        // DH3 = DH(EK_A, SPK_B)
        let dh3 = try myEphemeralKey.sharedSecretFromKeyAgreement(with: theirSignedPreKey)

        var dhResults = [dh1, dh2, dh3]

        // DH4 = DH(EK_A, OPK_B) — only if one-time pre-key was available
        if let opk = theirOneTimePreKey {
            let dh4 = try myEphemeralKey.sharedSecretFromKeyAgreement(with: opk)
            dhResults.append(dh4)
        }

        return deriveKeys(from: dhResults)
    }

    /// Bob (responder) computes the shared secret using Alice's initial message.
    static func responderKeyAgreement(
        myIdentityKey: Curve25519.KeyAgreement.PrivateKey,       // IK_B
        mySignedPreKey: Curve25519.KeyAgreement.PrivateKey,      // SPK_B
        myOneTimePreKey: Curve25519.KeyAgreement.PrivateKey?,    // OPK_B (optional)
        theirIdentityKey: Curve25519.KeyAgreement.PublicKey,     // IK_A
        theirEphemeralKey: Curve25519.KeyAgreement.PublicKey      // EK_A
    ) throws -> KeyAgreementResult {
        // DH1 = DH(SPK_B, IK_A) — same shared secret as DH(IK_A, SPK_B)
        let dh1 = try mySignedPreKey.sharedSecretFromKeyAgreement(with: theirIdentityKey)
        // DH2 = DH(IK_B, EK_A)
        let dh2 = try myIdentityKey.sharedSecretFromKeyAgreement(with: theirEphemeralKey)
        // DH3 = DH(SPK_B, EK_A)
        let dh3 = try mySignedPreKey.sharedSecretFromKeyAgreement(with: theirEphemeralKey)

        var dhResults = [dh1, dh2, dh3]

        if let opk = myOneTimePreKey {
            let dh4 = try opk.sharedSecretFromKeyAgreement(with: theirEphemeralKey)
            dhResults.append(dh4)
        }

        return deriveKeys(from: dhResults)
    }

    // MARK: - Private

    private static func deriveKeys(from secrets: [SharedSecret]) -> KeyAgreementResult {
        // Concatenate all DH outputs
        var ikm = Data()
        for secret in secrets {
            // Extract raw bytes from SharedSecret via HKDF with empty salt/info
            let key = secret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: Data(),
                sharedInfo: Data(),
                outputByteCount: 32
            )
            key.withUnsafeBytes { ikm.append(contentsOf: $0) }
        }

        // Derive root key and chain key using HKDF
        let salt = Data(repeating: 0, count: 32) // Zero salt per Signal spec
        let info = "PeerDrop-X3DH-v1".data(using: .utf8)!

        // Use HKDF to derive 64 bytes: first 32 = root key, second 32 = chain key
        let prk = HMAC<SHA256>.authenticationCode(for: ikm, using: SymmetricKey(data: salt))
        let prkKey = SymmetricKey(data: Data(prk))

        // T(1) = HMAC(PRK, info || 0x01)
        var t1Input = info
        t1Input.append(0x01)
        let t1 = Data(HMAC<SHA256>.authenticationCode(for: t1Input, using: prkKey))

        // T(2) = HMAC(PRK, T(1) || info || 0x02)
        var t2Input = t1
        t2Input.append(contentsOf: info)
        t2Input.append(0x02)
        let t2 = Data(HMAC<SHA256>.authenticationCode(for: t2Input, using: prkKey))

        return KeyAgreementResult(
            rootKey: SymmetricKey(data: t1),
            chainKey: SymmetricKey(data: t2)
        )
    }
}
```

**Step 4: Run tests**

Run: `xcodegen generate && xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/X3DHTests 2>&1 | tail -20`
Expected: ALL PASS

**Step 5: Commit**

```bash
git add PeerDrop/Security/Protocol/X3DH.swift PeerDropTests/X3DHTests.swift
git commit -m "feat: add X3DH key agreement protocol implementation"
```

---

## Task 4: DoubleRatchet — Per-Message Forward Secrecy

The Double Ratchet algorithm provides forward secrecy and break-in recovery for ongoing message encryption. Each message gets a unique key that is destroyed after use.

**Files:**
- Create: `PeerDrop/Security/Protocol/DoubleRatchet.swift`
- Create: `PeerDropTests/DoubleRatchetTests.swift`

**Step 1: Write the failing tests**

```swift
// PeerDropTests/DoubleRatchetTests.swift
import XCTest
import CryptoKit
@testable import PeerDrop

final class DoubleRatchetTests: XCTestCase {

    private func createSessionPair() throws -> (alice: DoubleRatchetSession, bob: DoubleRatchetSession) {
        // Simulate X3DH to get shared root/chain keys
        let aliceIdentity = Curve25519.KeyAgreement.PrivateKey()
        let aliceEphemeral = Curve25519.KeyAgreement.PrivateKey()
        let bobIdentity = Curve25519.KeyAgreement.PrivateKey()
        let bobSignedPreKey = Curve25519.KeyAgreement.PrivateKey()

        let aliceX3DH = try X3DH.initiatorKeyAgreement(
            myIdentityKey: aliceIdentity,
            myEphemeralKey: aliceEphemeral,
            theirIdentityKey: bobIdentity.publicKey,
            theirSignedPreKey: bobSignedPreKey.publicKey,
            theirOneTimePreKey: nil
        )
        let bobX3DH = try X3DH.responderKeyAgreement(
            myIdentityKey: bobIdentity,
            mySignedPreKey: bobSignedPreKey,
            myOneTimePreKey: nil,
            theirIdentityKey: aliceIdentity.publicKey,
            theirEphemeralKey: aliceEphemeral.publicKey
        )

        let alice = DoubleRatchetSession.initializeAsInitiator(
            rootKey: aliceX3DH.rootKey,
            theirRatchetKey: bobSignedPreKey.publicKey
        )
        let bob = DoubleRatchetSession.initializeAsResponder(
            rootKey: bobX3DH.rootKey,
            myRatchetKey: bobSignedPreKey
        )
        return (alice, bob)
    }

    func testSingleMessageEncryptDecrypt() throws {
        let (alice, bob) = try createSessionPair()
        let plaintext = "Hello Bob!".data(using: .utf8)!

        let encrypted = try alice.encrypt(plaintext)
        let decrypted = try bob.decrypt(encrypted)

        XCTAssertEqual(decrypted, plaintext)
    }

    func testMultipleMessagesOneDirection() throws {
        let (alice, bob) = try createSessionPair()

        for i in 0..<5 {
            let msg = "Message \(i)".data(using: .utf8)!
            let encrypted = try alice.encrypt(msg)
            let decrypted = try bob.decrypt(encrypted)
            XCTAssertEqual(decrypted, msg)
        }
    }

    func testBidirectionalMessages() throws {
        let (alice, bob) = try createSessionPair()

        let m1 = try alice.encrypt("Alice to Bob 1".data(using: .utf8)!)
        XCTAssertEqual(try bob.decrypt(m1), "Alice to Bob 1".data(using: .utf8)!)

        let m2 = try bob.encrypt("Bob to Alice 1".data(using: .utf8)!)
        XCTAssertEqual(try alice.decrypt(m2), "Bob to Alice 1".data(using: .utf8)!)

        let m3 = try alice.encrypt("Alice to Bob 2".data(using: .utf8)!)
        XCTAssertEqual(try bob.decrypt(m3), "Alice to Bob 2".data(using: .utf8)!)
    }

    func testOutOfOrderMessages() throws {
        let (alice, bob) = try createSessionPair()

        let m1 = try alice.encrypt("First".data(using: .utf8)!)
        let m2 = try alice.encrypt("Second".data(using: .utf8)!)
        let m3 = try alice.encrypt("Third".data(using: .utf8)!)

        // Deliver out of order
        XCTAssertEqual(try bob.decrypt(m3), "Third".data(using: .utf8)!)
        XCTAssertEqual(try bob.decrypt(m1), "First".data(using: .utf8)!)
        XCTAssertEqual(try bob.decrypt(m2), "Second".data(using: .utf8)!)
    }

    func testReplayProtection() throws {
        let (alice, bob) = try createSessionPair()

        let encrypted = try alice.encrypt("Hello".data(using: .utf8)!)
        _ = try bob.decrypt(encrypted)

        // Replaying the same message should fail
        XCTAssertThrowsError(try bob.decrypt(encrypted))
    }

    func testForwardSecrecy() throws {
        let (alice, bob) = try createSessionPair()

        let m1 = try alice.encrypt("Secret 1".data(using: .utf8)!)
        _ = try bob.decrypt(m1)

        // After more messages, old keys are gone
        for i in 0..<10 {
            let msg = try alice.encrypt("msg \(i)".data(using: .utf8)!)
            _ = try bob.decrypt(msg)
        }

        // Cannot decrypt m1 again (key was destroyed)
        XCTAssertThrowsError(try bob.decrypt(m1))
    }

    func testEachMessageHasUniqueKey() throws {
        let (alice, _) = try createSessionPair()

        let e1 = try alice.encrypt("Same message".data(using: .utf8)!)
        let e2 = try alice.encrypt("Same message".data(using: .utf8)!)

        // Same plaintext, different ciphertext (different keys + nonces)
        XCTAssertNotEqual(e1.ciphertext, e2.ciphertext)
    }
}
```

**Step 2: Run tests to verify they fail**

**Step 3: Write the implementation**

```swift
// PeerDrop/Security/Protocol/DoubleRatchet.swift
import Foundation
import CryptoKit

/// A message encrypted by the Double Ratchet, ready for wire transmission.
struct RatchetMessage: Codable {
    let ratchetKey: Data        // Sender's current DH ratchet public key
    let counter: UInt32         // Message number in current chain
    let previousCounter: UInt32 // Length of previous sending chain
    let ciphertext: Data        // AES-256-GCM encrypted (nonce + ciphertext + tag)
}

/// Double Ratchet session providing per-message forward secrecy.
/// Reference: https://signal.org/docs/specifications/doubleratchet/
class DoubleRatchetSession {

    // DH Ratchet state
    private var myRatchetKey: Curve25519.KeyAgreement.PrivateKey
    private var theirRatchetKey: Curve25519.KeyAgreement.PublicKey?

    // Symmetric Ratchet state
    private var rootKey: SymmetricKey
    private var sendChainKey: SymmetricKey?
    private var receiveChainKey: SymmetricKey?

    // Message counters
    private var sendCounter: UInt32 = 0
    private var receiveCounter: UInt32 = 0
    private var previousSendCounter: UInt32 = 0

    // Skipped message keys for out-of-order delivery (max 200)
    private var skippedKeys: [SkippedKeyIndex: SymmetricKey] = [:]
    private static let maxSkip: UInt32 = 200

    private struct SkippedKeyIndex: Hashable {
        let ratchetKey: Data
        let counter: UInt32
    }

    private init(rootKey: SymmetricKey, myRatchetKey: Curve25519.KeyAgreement.PrivateKey) {
        self.rootKey = rootKey
        self.myRatchetKey = myRatchetKey
    }

    // MARK: - Initialization

    /// Alice (initiator) initializes after X3DH.
    /// She knows Bob's signed pre-key as the initial ratchet key.
    static func initializeAsInitiator(
        rootKey: SymmetricKey,
        theirRatchetKey: Curve25519.KeyAgreement.PublicKey
    ) -> DoubleRatchetSession {
        let myRatchetKey = Curve25519.KeyAgreement.PrivateKey()
        let session = DoubleRatchetSession(rootKey: rootKey, myRatchetKey: myRatchetKey)
        session.theirRatchetKey = theirRatchetKey

        // Perform initial DH ratchet step
        let (newRootKey, sendChain) = session.dhRatchetStep(
            rootKey: rootKey,
            myKey: myRatchetKey,
            theirKey: theirRatchetKey
        )
        session.rootKey = newRootKey
        session.sendChainKey = sendChain
        return session
    }

    /// Bob (responder) initializes after X3DH.
    /// His signed pre-key is the initial ratchet key.
    static func initializeAsResponder(
        rootKey: SymmetricKey,
        myRatchetKey: Curve25519.KeyAgreement.PrivateKey
    ) -> DoubleRatchetSession {
        let session = DoubleRatchetSession(rootKey: rootKey, myRatchetKey: myRatchetKey)
        // No send chain yet — will be created when we first send
        // Receive chain will be derived when we get Alice's first message
        return session
    }

    // MARK: - Encrypt

    func encrypt(_ plaintext: Data) throws -> RatchetMessage {
        guard let chainKey = sendChainKey else {
            throw DoubleRatchetError.noSendChain
        }

        let (messageKey, newChainKey) = symmetricRatchetStep(chainKey: chainKey)
        sendChainKey = newChainKey

        let sealedBox = try AES.GCM.seal(plaintext, using: messageKey)
        guard let combined = sealedBox.combined else {
            throw DoubleRatchetError.encryptionFailed
        }

        let message = RatchetMessage(
            ratchetKey: myRatchetKey.publicKey.rawRepresentation,
            counter: sendCounter,
            previousCounter: previousSendCounter,
            ciphertext: combined
        )
        sendCounter += 1
        return message
    }

    // MARK: - Decrypt

    func decrypt(_ message: RatchetMessage) throws -> Data {
        // Check skipped keys first (out-of-order message)
        let skipIndex = SkippedKeyIndex(ratchetKey: message.ratchetKey, counter: message.counter)
        if let skippedKey = skippedKeys.removeValue(forKey: skipIndex) {
            return try decryptWithKey(message.ciphertext, key: skippedKey)
        }

        // Check if this is a new DH ratchet key
        if theirRatchetKey == nil || message.ratchetKey != theirRatchetKey!.rawRepresentation {
            // Skip any remaining messages from the old chain
            if let oldReceiveChain = receiveChainKey, let oldTheirKey = theirRatchetKey {
                try skipMessages(
                    until: message.previousCounter,
                    chainKey: &receiveChainKey!,
                    theirRatchetKey: oldTheirKey.rawRepresentation
                )
            }

            // DH Ratchet step: derive new receive chain
            let newTheirKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: message.ratchetKey)
            let (rootKey1, receiveChain) = dhRatchetStep(rootKey: rootKey, myKey: myRatchetKey, theirKey: newTheirKey)

            // Generate new ratchet key pair for sending
            previousSendCounter = sendCounter
            sendCounter = 0
            receiveCounter = 0
            theirRatchetKey = newTheirKey

            let newMyRatchetKey = Curve25519.KeyAgreement.PrivateKey()
            let (rootKey2, sendChain) = dhRatchetStep(rootKey: rootKey1, myKey: newMyRatchetKey, theirKey: newTheirKey)

            myRatchetKey = newMyRatchetKey
            rootKey = rootKey2
            sendChainKey = sendChain
            receiveChainKey = receiveChain
        }

        guard var chainKey = receiveChainKey else {
            throw DoubleRatchetError.noReceiveChain
        }

        // Skip ahead if needed
        try skipMessages(until: message.counter, chainKey: &chainKey, theirRatchetKey: message.ratchetKey)
        receiveChainKey = chainKey

        // Derive message key
        let (messageKey, newChainKey) = symmetricRatchetStep(chainKey: chainKey)
        receiveChainKey = newChainKey
        receiveCounter = message.counter + 1

        return try decryptWithKey(message.ciphertext, key: messageKey)
    }

    // MARK: - Private

    private func dhRatchetStep(
        rootKey: SymmetricKey,
        myKey: Curve25519.KeyAgreement.PrivateKey,
        theirKey: Curve25519.KeyAgreement.PublicKey
    ) -> (newRootKey: SymmetricKey, chainKey: SymmetricKey) {
        let shared = try! myKey.sharedSecretFromKeyAgreement(with: theirKey)
        let sharedData: Data = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: Data(), sharedInfo: Data(), outputByteCount: 32
        ).withUnsafeBytes { Data($0) }

        // KDF(rootKey, DH_output) -> (newRootKey, chainKey)
        let info = "PeerDrop-Ratchet-v1".data(using: .utf8)!
        var salt = Data()
        rootKey.withUnsafeBytes { salt.append(contentsOf: $0) }

        let prk = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: sharedData, using: SymmetricKey(data: salt))))

        var t1Input = info; t1Input.append(0x01)
        let newRoot = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: t1Input, using: prk)))

        var t2Input = Data(HMAC<SHA256>.authenticationCode(for: t1Input, using: prk))
        t2Input.append(contentsOf: info); t2Input.append(0x02)
        let chain = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: t2Input, using: prk)))

        return (newRoot, chain)
    }

    private func symmetricRatchetStep(chainKey: SymmetricKey) -> (messageKey: SymmetricKey, newChainKey: SymmetricKey) {
        // messageKey = HMAC(chainKey, 0x01)
        let msgKey = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(
            for: Data([0x01]), using: chainKey
        )))
        // newChainKey = HMAC(chainKey, 0x02)
        let newChain = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(
            for: Data([0x02]), using: chainKey
        )))
        return (msgKey, newChain)
    }

    private func skipMessages(until target: UInt32, chainKey: inout SymmetricKey, theirRatchetKey: Data) throws {
        guard target > receiveCounter else { return }
        guard target - receiveCounter <= Self.maxSkip else {
            throw DoubleRatchetError.tooManySkippedMessages
        }

        for i in receiveCounter..<target {
            let (msgKey, newChain) = symmetricRatchetStep(chainKey: chainKey)
            skippedKeys[SkippedKeyIndex(ratchetKey: theirRatchetKey, counter: i)] = msgKey
            chainKey = newChain
        }
    }

    private func decryptWithKey(_ ciphertext: Data, key: SymmetricKey) throws -> Data {
        let sealedBox = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(sealedBox, using: key)
    }

    enum DoubleRatchetError: Error {
        case noSendChain
        case noReceiveChain
        case encryptionFailed
        case tooManySkippedMessages
    }
}
```

**Step 4: Run tests**

Run: `xcodegen generate && xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/DoubleRatchetTests 2>&1 | tail -20`
Expected: ALL PASS

**Step 5: Commit**

```bash
git add PeerDrop/Security/Protocol/DoubleRatchet.swift PeerDropTests/DoubleRatchetTests.swift
git commit -m "feat: add Double Ratchet session with per-message forward secrecy"
```

---

## Task 5: ProofOfWork — Hashcash-Style Anti-Abuse

Client-side computation required for each remote message. Prevents spam without sacrificing privacy.

**Files:**
- Create: `PeerDrop/Security/Protocol/ProofOfWork.swift`
- Create: `PeerDropTests/ProofOfWorkTests.swift`

**Step 1: Write the failing tests**

```swift
// PeerDropTests/ProofOfWorkTests.swift
import XCTest
@testable import PeerDrop

final class ProofOfWorkTests: XCTestCase {

    func testGenerateProof() {
        let challenge = "test-challenge-\(Date().timeIntervalSince1970)"
        let proof = ProofOfWork.generate(challenge: challenge, difficulty: 16)
        XCTAssertNotNil(proof)
        XCTAssertTrue(ProofOfWork.verify(challenge: challenge, proof: proof!, difficulty: 16))
    }

    func testVerifyRejectsWrongProof() {
        let challenge = "test-challenge"
        XCTAssertFalse(ProofOfWork.verify(challenge: challenge, proof: 12345, difficulty: 16))
    }

    func testVerifyRejectsWrongChallenge() {
        let challenge = "test-challenge-\(Date().timeIntervalSince1970)"
        let proof = ProofOfWork.generate(challenge: challenge, difficulty: 16)!
        XCTAssertFalse(ProofOfWork.verify(challenge: "wrong-challenge", proof: proof, difficulty: 16))
    }

    func testDifficulty16CompletesQuickly() {
        let start = Date()
        let challenge = "perf-test-\(UUID().uuidString)"
        let proof = ProofOfWork.generate(challenge: challenge, difficulty: 16)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertNotNil(proof)
        XCTAssertLessThan(elapsed, 2.0) // Should complete well under 2 seconds
    }
}
```

**Step 3: Write the implementation**

```swift
// PeerDrop/Security/Protocol/ProofOfWork.swift
import Foundation
import CryptoKit

/// Hashcash-style Proof-of-Work to prevent relay abuse.
/// Normal usage: ~50-100ms per proof. Bulk spamming: prohibitively expensive.
enum ProofOfWork {

    /// Generate a proof of work for the given challenge.
    /// Finds a nonce such that SHA256(challenge + nonce) has `difficulty` leading zero bits.
    static func generate(challenge: String, difficulty: Int = 16, maxIterations: Int = 10_000_000) -> UInt64? {
        let challengeData = Data(challenge.utf8)
        for nonce in UInt64(0)..<UInt64(maxIterations) {
            var data = challengeData
            withUnsafeBytes(of: nonce.bigEndian) { data.append(contentsOf: $0) }
            let hash = SHA256.hash(data: data)
            if hasLeadingZeroBits(hash: hash, count: difficulty) {
                return nonce
            }
        }
        return nil
    }

    /// Verify a proof of work.
    static func verify(challenge: String, proof: UInt64, difficulty: Int = 16) -> Bool {
        var data = Data(challenge.utf8)
        withUnsafeBytes(of: proof.bigEndian) { data.append(contentsOf: $0) }
        let hash = SHA256.hash(data: data)
        return hasLeadingZeroBits(hash: hash, count: difficulty)
    }

    private static func hasLeadingZeroBits(hash: SHA256.Digest, count: Int) -> Bool {
        let bytes = Array(hash)
        var zeroBits = 0
        for byte in bytes {
            if byte == 0 {
                zeroBits += 8
            } else {
                zeroBits += byte.leadingZeroBitCount
                break
            }
            if zeroBits >= count { return true }
        }
        return zeroBits >= count
    }
}
```

**Step 4: Run tests, Step 5: Commit**

```bash
git add PeerDrop/Security/Protocol/ProofOfWork.swift PeerDropTests/ProofOfWorkTests.swift
git commit -m "feat: add Hashcash-style Proof-of-Work for relay anti-abuse"
```

---

## Task 6: Cloudflare Worker v2 API — Pre-Key Server & Mailbox

Extend the existing Cloudflare Worker with v2 endpoints for pre-key distribution, anonymous mailbox, and message relay.

**Files:**
- Modify: `cloudflare-worker/src/index.ts`
- Modify: `cloudflare-worker/wrangler.toml` (add KV namespace for v2 if needed)

**Step 1: Read current worker code**

Read `cloudflare-worker/src/index.ts` and `cloudflare-worker/wrangler.toml` to understand existing structure.

**Step 2: Add v2 endpoints to the worker**

Add the following endpoints alongside existing ones. Use the existing `ROOMS` KV namespace for all storage (or add a new `V2_STORE` namespace if separation is preferred).

```typescript
// === v2 API: Pre-Key Server & Anonymous Mailbox ===

// POST /v2/keys/register — Upload device's public key bundle
// Body: { mailboxId, preKeyBundle: { identityKey, signingKey, signedPreKey, oneTimePreKeys } }
// Auth: Proof-of-Work header (X-PoW-Challenge, X-PoW-Proof)
// Storage: KV key "keys:{mailboxId}" with TTL 30 days
// Rate limit: 10 req/min per IP

// GET /v2/keys/:mailboxId — Retrieve target's pre-key bundle
// Returns: { identityKey, signingKey, signedPreKey, oneTimePreKey? }
// Consumes ONE one-time pre-key (removes it from the stored bundle)
// If no one-time pre-keys left, returns bundle without oneTimePreKey

// POST /v2/messages/:mailboxId — Deliver encrypted message to target
// Body: { ciphertext (base64), pow: { challenge, proof } }
// Storage: KV key "msg:{mailboxId}:{timestamp}" with TTL 7 days
// Rate limit: 200 msg/day per mailboxId (tracked in KV)

// GET /v2/messages — Pull pending messages for own mailbox
// Auth: X-Mailbox-Id + X-Mailbox-Token header
// Returns: array of { id, ciphertext, timestamp }
// Server DELETES messages after successful pull

// POST /v2/mailbox/rotate — Rotate mailbox ID
// Auth: Old mailbox token
// Generates new mailboxId + token, migrates pending messages
// Returns: { newMailboxId, newToken }

// DELETE /v2/keys — Revoke all keys (device lost)
// Auth: X-Mailbox-Id + X-Mailbox-Token
// Deletes key bundle and all pending messages
```

**Implementation considerations:**
- Use existing `checkRateLimit()` function with different thresholds per endpoint
- Store mailbox tokens in KV with same pattern as room tokens
- Pre-key consumption must be atomic (use KV CAS if available, or Durable Object)
- Message storage: KV list with prefix `msg:{mailboxId}:` for efficient retrieval
- PoW verification: Implement same SHA256 check as client-side
- No logging of content, IPs, or sender-recipient relationships

**Step 3: Test locally**

```bash
cd cloudflare-worker && npx wrangler dev
# In another terminal:
curl -X POST http://localhost:8787/v2/keys/register -H "Content-Type: application/json" -d '{"mailboxId":"test123","preKeyBundle":{...}}'
```

**Step 4: Commit**

```bash
git add cloudflare-worker/src/index.ts cloudflare-worker/wrangler.toml
git commit -m "feat: add Cloudflare Worker v2 API for pre-key server and anonymous mailbox"
```

---

## Task 7: MailboxClient — iOS HTTP Client for v2 API

Swift client for interacting with the v2 relay API.

**Files:**
- Create: `PeerDrop/Transport/MailboxClient.swift`
- Create: `PeerDropTests/MailboxClientTests.swift`

**Step 1: Write the implementation**

```swift
// PeerDrop/Transport/MailboxClient.swift
import Foundation
import os.log

/// HTTP client for the v2 zero-knowledge relay API.
/// Handles pre-key registration, message delivery, and mailbox management.
actor MailboxClient {

    private static let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "MailboxClient")

    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL? = nil) {
        self.baseURL = baseURL ?? URL(string:
            UserDefaults.standard.string(forKey: "workerBaseURL")
            ?? "https://peerdrop-signal.hanfourhuang.workers.dev"
        )!
        let config = URLSessionConfiguration.ephemeral // No caching, no cookies
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    // MARK: - Pre-Key Management

    func registerPreKeys(mailboxId: String, bundle: PreKeyBundle) async throws {
        let url = baseURL.appendingPathComponent("v2/keys/register")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = RegisterKeysRequest(mailboxId: mailboxId, preKeyBundle: bundle)
        request.httpBody = try JSONEncoder().encode(body)

        let (_, response) = try await session.data(for: request)
        try validateResponse(response)
    }

    func fetchPreKeyBundle(mailboxId: String) async throws -> PreKeyBundle {
        let url = baseURL.appendingPathComponent("v2/keys/\(mailboxId)")
        let (data, response) = try await session.data(from: url)
        try validateResponse(response)
        return try JSONDecoder().decode(PreKeyBundle.self, from: data)
    }

    // MARK: - Message Delivery

    func sendMessage(to mailboxId: String, ciphertext: Data, pow: ProofOfWorkToken) async throws {
        let url = baseURL.appendingPathComponent("v2/messages/\(mailboxId)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = SendMessageRequest(
            ciphertext: ciphertext.base64EncodedString(),
            pow: pow
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (_, response) = try await session.data(for: request)
        try validateResponse(response)
    }

    func fetchMessages(mailboxId: String, token: String) async throws -> [MailboxMessage] {
        let url = baseURL.appendingPathComponent("v2/messages")
        var request = URLRequest(url: url)
        request.setValue(mailboxId, forHTTPHeaderField: "X-Mailbox-Id")
        request.setValue(token, forHTTPHeaderField: "X-Mailbox-Token")

        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        return try JSONDecoder().decode([MailboxMessage].self, from: data)
    }

    // MARK: - Mailbox Management

    func rotateMailbox(oldMailboxId: String, oldToken: String) async throws -> MailboxRotationResult {
        let url = baseURL.appendingPathComponent("v2/mailbox/rotate")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(oldMailboxId, forHTTPHeaderField: "X-Mailbox-Id")
        request.setValue(oldToken, forHTTPHeaderField: "X-Mailbox-Token")

        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        return try JSONDecoder().decode(MailboxRotationResult.self, from: data)
    }

    func revokeKeys(mailboxId: String, token: String) async throws {
        let url = baseURL.appendingPathComponent("v2/keys")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(mailboxId, forHTTPHeaderField: "X-Mailbox-Id")
        request.setValue(token, forHTTPHeaderField: "X-Mailbox-Token")

        let (_, response) = try await session.data(for: request)
        try validateResponse(response)
    }

    // MARK: - Private

    private func validateResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MailboxError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw MailboxError.httpError(httpResponse.statusCode)
        }
    }
}

// MARK: - Request/Response Models

struct RegisterKeysRequest: Codable {
    let mailboxId: String
    let preKeyBundle: PreKeyBundle
}

struct SendMessageRequest: Codable {
    let ciphertext: String
    let pow: ProofOfWorkToken
}

struct ProofOfWorkToken: Codable {
    let challenge: String
    let proof: UInt64
}

struct MailboxMessage: Codable, Identifiable {
    let id: String
    let ciphertext: String
    let timestamp: Date
}

struct MailboxRotationResult: Codable {
    let newMailboxId: String
    let newToken: String
}

enum MailboxError: Error {
    case invalidResponse
    case httpError(Int)
}
```

**Step 2: Commit**

```bash
git add PeerDrop/Transport/MailboxClient.swift
git commit -m "feat: add MailboxClient for v2 zero-knowledge relay API"
```

---

## Task 8: MailboxManager — Mailbox Lifecycle and Message Sync

Manages the device's mailbox ID, token, periodic message polling, and pre-key upload.

**Files:**
- Create: `PeerDrop/Transport/MailboxManager.swift`
- Create: `PeerDropTests/MailboxManagerTests.swift`

**Step 1: Write the implementation**

```swift
// PeerDrop/Transport/MailboxManager.swift
import Foundation
import Combine
import os.log

/// Manages the device's anonymous mailbox on the zero-knowledge relay.
/// Handles mailbox registration, message polling, pre-key upload, and rotation.
@MainActor
final class MailboxManager: ObservableObject {

    private static let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "MailboxManager")

    @Published private(set) var mailboxId: String?
    @Published private(set) var isRegistered = false
    @Published private(set) var pendingMessages: [MailboxMessage] = []

    private let client: MailboxClient
    private let preKeyStore: PreKeyStore
    private var mailboxToken: String?
    private var pollTask: Task<Void, Never>?

    private static let mailboxIdKey = "peerDropMailboxId"
    private static let mailboxTokenKey = "peerDropMailboxToken"

    var onMessageReceived: ((MailboxMessage) -> Void)?

    init(client: MailboxClient = MailboxClient(), preKeyStore: PreKeyStore = PreKeyStore()) {
        self.client = client
        self.preKeyStore = preKeyStore

        // Load persisted mailbox credentials
        self.mailboxId = UserDefaults.standard.string(forKey: Self.mailboxIdKey)
        self.mailboxToken = loadTokenFromKeychain()
        self.isRegistered = mailboxId != nil && mailboxToken != nil
    }

    // MARK: - Registration

    func registerIfNeeded() async throws {
        guard !isRegistered else { return }

        let newMailboxId = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24).lowercased()
        let bundle = preKeyStore.generatePreKeyBundle()

        try await client.registerPreKeys(mailboxId: String(newMailboxId), bundle: bundle)

        // TODO: Server should return a token. For now, generate locally.
        let token = UUID().uuidString
        self.mailboxId = String(newMailboxId)
        self.mailboxToken = token
        self.isRegistered = true

        UserDefaults.standard.set(mailboxId, forKey: Self.mailboxIdKey)
        saveTokenToKeychain(token)

        Self.logger.info("Mailbox registered: \(String(newMailboxId))")
    }

    // MARK: - Message Polling

    func startPolling(interval: TimeInterval = 30) {
        stopPolling()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollMessages()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func pollMessages() async {
        guard let mailboxId, let token = mailboxToken else { return }
        do {
            let messages = try await client.fetchMessages(mailboxId: mailboxId, token: token)
            for msg in messages {
                pendingMessages.append(msg)
                onMessageReceived?(msg)
            }
        } catch {
            Self.logger.error("Failed to poll messages: \(error.localizedDescription)")
        }
    }

    // MARK: - Pre-Key Maintenance

    func uploadPreKeysIfNeeded() async {
        preKeyStore.rotateSignedPreKeyIfNeeded()
        preKeyStore.replenishOneTimePreKeysIfNeeded()

        guard let mailboxId else { return }
        let bundle = preKeyStore.generatePreKeyBundle()
        do {
            try await client.registerPreKeys(mailboxId: mailboxId, bundle: bundle)
            Self.logger.info("Pre-keys uploaded successfully")
        } catch {
            Self.logger.error("Failed to upload pre-keys: \(error.localizedDescription)")
        }
    }

    // MARK: - Mailbox Rotation

    func rotateMailbox() async throws {
        guard let oldId = mailboxId, let oldToken = mailboxToken else { return }
        let result = try await client.rotateMailbox(oldMailboxId: oldId, oldToken: oldToken)

        self.mailboxId = result.newMailboxId
        self.mailboxToken = result.newToken

        UserDefaults.standard.set(result.newMailboxId, forKey: Self.mailboxIdKey)
        saveTokenToKeychain(result.newToken)

        Self.logger.info("Mailbox rotated to: \(result.newMailboxId)")
    }

    // MARK: - Keychain Token Storage

    private func saveTokenToKeychain(_ token: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.peerdrop.mailbox",
            kSecAttrAccount as String: "mailbox-token",
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    private func loadTokenFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.peerdrop.mailbox",
            kSecAttrAccount as String: "mailbox-token",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
```

**Step 2: Commit**

```bash
git add PeerDrop/Transport/MailboxManager.swift
git commit -m "feat: add MailboxManager for mailbox lifecycle and message sync"
```

---

## Task 9: RemoteSessionManager — Orchestrate X3DH + Double Ratchet for Remote Peers

Ties together X3DH key agreement, Double Ratchet encryption, and the MailboxClient to enable encrypted remote messaging.

**Files:**
- Create: `PeerDrop/Security/Protocol/RemoteSessionManager.swift`
- Create: `PeerDropTests/RemoteSessionManagerTests.swift`

**Step 1: Write the implementation**

```swift
// PeerDrop/Security/Protocol/RemoteSessionManager.swift
import Foundation
import CryptoKit
import os.log

/// Manages encrypted remote sessions with peers via X3DH + Double Ratchet.
/// Coordinates with MailboxClient for message delivery and PreKeyStore for key material.
@MainActor
final class RemoteSessionManager: ObservableObject {

    private static let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "RemoteSessionManager")

    private var sessions: [String: DoubleRatchetSession] = [:] // keyed by contact UUID
    private let preKeyStore: PreKeyStore
    private let mailboxClient: MailboxClient

    init(preKeyStore: PreKeyStore = PreKeyStore(), mailboxClient: MailboxClient = MailboxClient()) {
        self.preKeyStore = preKeyStore
        self.mailboxClient = mailboxClient
    }

    // MARK: - Initiate Session (Alice side)

    /// Start a new remote session with a peer by fetching their pre-key bundle.
    func initiateSession(
        contactId: String,
        peerMailboxId: String
    ) async throws -> DoubleRatchetSession {
        // Fetch peer's pre-key bundle from relay
        let bundle = try await mailboxClient.fetchPreKeyBundle(mailboxId: peerMailboxId)

        // Validate signed pre-key
        let signingPub = try Curve25519.Signing.PublicKey(rawRepresentation: bundle.signingKey)
        guard bundle.signedPreKey.verify(with: signingPub) else {
            throw RemoteSessionError.invalidSignedPreKey
        }

        let theirIdentityKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: bundle.identityKey)
        let theirSignedPreKey = try bundle.signedPreKey.agreementPublicKey()

        // Use one-time pre-key if available
        var theirOneTimePreKey: Curve25519.KeyAgreement.PublicKey?
        if let otpk = bundle.oneTimePreKeys.first {
            theirOneTimePreKey = try otpk.agreementPublicKey()
        }

        // X3DH key agreement
        let ephemeralKey = Curve25519.KeyAgreement.PrivateKey()
        let x3dhResult = try X3DH.initiatorKeyAgreement(
            myIdentityKey: IdentityKeyManager.shared.agreementPrivateKeyForX3DH(),
            myEphemeralKey: ephemeralKey,
            theirIdentityKey: theirIdentityKey,
            theirSignedPreKey: theirSignedPreKey,
            theirOneTimePreKey: theirOneTimePreKey
        )

        // Initialize Double Ratchet
        let session = DoubleRatchetSession.initializeAsInitiator(
            rootKey: x3dhResult.rootKey,
            theirRatchetKey: theirSignedPreKey
        )

        sessions[contactId] = session
        Self.logger.info("Remote session initiated with contact \(contactId)")
        return session
    }

    // MARK: - Respond to Session (Bob side)

    /// Handle an incoming X3DH initial message and create a session.
    func respondToSession(
        contactId: String,
        theirIdentityKey: Data,
        theirEphemeralKey: Data,
        usedSignedPreKeyId: UInt32,
        usedOneTimePreKeyId: UInt32?
    ) throws -> DoubleRatchetSession {
        let theirIdKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirIdentityKey)
        let theirEphKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirEphemeralKey)

        guard let signedPreKey = try preKeyStore.signedPreKey(for: usedSignedPreKeyId) else {
            throw RemoteSessionError.unknownSignedPreKey
        }

        var oneTimePreKey: Curve25519.KeyAgreement.PrivateKey?
        if let otpkId = usedOneTimePreKeyId,
           let otpk = try preKeyStore.consumeOneTimePreKey(id: otpkId) {
            oneTimePreKey = try otpk.agreementPrivateKey()
        }

        let x3dhResult = try X3DH.responderKeyAgreement(
            myIdentityKey: IdentityKeyManager.shared.agreementPrivateKeyForX3DH(),
            mySignedPreKey: try signedPreKey.agreementPrivateKey(),
            myOneTimePreKey: oneTimePreKey,
            theirIdentityKey: theirIdKey,
            theirEphemeralKey: theirEphKey
        )

        let mySignedPreKeyPrivate = try signedPreKey.agreementPrivateKey()
        let session = DoubleRatchetSession.initializeAsResponder(
            rootKey: x3dhResult.rootKey,
            myRatchetKey: mySignedPreKeyPrivate
        )

        sessions[contactId] = session
        Self.logger.info("Remote session established as responder for contact \(contactId)")
        return session
    }

    // MARK: - Encrypt / Decrypt

    func encrypt(data: Data, for contactId: String) throws -> RatchetMessage {
        guard let session = sessions[contactId] else {
            throw RemoteSessionError.noSession
        }
        return try session.encrypt(data)
    }

    func decrypt(message: RatchetMessage, from contactId: String) throws -> Data {
        guard let session = sessions[contactId] else {
            throw RemoteSessionError.noSession
        }
        return try session.decrypt(message)
    }

    func hasSession(for contactId: String) -> Bool {
        sessions[contactId] != nil
    }

    enum RemoteSessionError: Error {
        case invalidSignedPreKey
        case unknownSignedPreKey
        case noSession
    }
}
```

Note: `IdentityKeyManager.shared.agreementPrivateKeyForX3DH()` needs to be added — a method that exposes the private key for X3DH. This is a controlled exposure (only used within the security layer). Add to IdentityKeyManager:

```swift
/// Expose agreement private key for X3DH key agreement. Only used within Security layer.
func agreementPrivateKeyForX3DH() -> Curve25519.KeyAgreement.PrivateKey {
    agreementPrivateKey
}
```

Make `agreementPrivateKey` internal (remove `private`) or add the above method.

**Step 2: Commit**

```bash
git add PeerDrop/Security/Protocol/RemoteSessionManager.swift PeerDrop/Security/IdentityKeyManager.swift
git commit -m "feat: add RemoteSessionManager orchestrating X3DH + Double Ratchet"
```

---

## Task 10: Remote Invite Link Flow

Create the UI and logic for generating and handling remote invite links (`peerdrop://invite?...`).

**Files:**
- Create: `PeerDrop/UI/Security/RemoteInviteView.swift`
- Modify: `PeerDrop/Security/PairingPayload.swift` — add invite URL format

This task creates the remote invite URL format and a view for generating/sharing invite links. The flow:
1. Alice generates invite link containing her mailboxId + identity key fingerprint
2. Carol opens link, PeerDrop fetches Alice's pre-key bundle from relay
3. X3DH key agreement establishes encrypted session
4. Both are added to each other's TrustedContactStore with `.linked` trust

**Step 1: Add invite URL to PairingPayload**

Add to `PairingPayload.swift`:

```swift
struct InvitePayload: Codable {
    let mailboxId: String
    let identityKeyFingerprint: String
    let displayName: String
    let expiry: Date

    func toURL() -> URL? {
        var components = URLComponents()
        components.scheme = "peerdrop"
        components.host = "invite"
        components.queryItems = [
            URLQueryItem(name: "mbx", value: mailboxId),
            URLQueryItem(name: "fp", value: identityKeyFingerprint),
            URLQueryItem(name: "name", value: displayName),
            URLQueryItem(name: "exp", value: String(Int(expiry.timeIntervalSince1970)))
        ]
        return components.url
    }

    init(from url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "peerdrop",
              components.host == "invite",
              let items = components.queryItems else {
            throw PairingPayload.PairingError.invalidURL
        }
        let dict = Dictionary(uniqueKeysWithValues: items.compactMap { $0.value.map { ($0.name, $1) } })
        guard let mbx = dict["mbx"], let fp = dict["fp"], let name = dict["name"],
              let expStr = dict["exp"], let expTs = TimeInterval(expStr) else {
            throw PairingPayload.PairingError.missingFields
        }
        self.mailboxId = mbx
        self.identityKeyFingerprint = fp
        self.displayName = name
        self.expiry = Date(timeIntervalSince1970: expTs)
    }
}
```

**Step 2: Create RemoteInviteView**

```swift
// PeerDrop/UI/Security/RemoteInviteView.swift
import SwiftUI

struct RemoteInviteView: View {
    @ObservedObject var mailboxManager: MailboxManager
    @State private var inviteURL: URL?
    @State private var isGenerating = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "link.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("Remote Invite")
                .font(.title2.bold())

            Text(String(localized: "Generate a link to connect with someone remotely. Share it via any messaging app."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let url = inviteURL {
                VStack(spacing: 12) {
                    Text(url.absoluteString)
                        .font(.system(.caption, design: .monospaced))
                        .padding()
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    ShareLink(item: url) {
                        Label(String(localized: "Share Invite Link"), systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Button(action: generateInvite) {
                    if isGenerating {
                        ProgressView()
                    } else {
                        Label(String(localized: "Generate Invite Link"), systemImage: "link")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isGenerating)
            }

            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.green)
                Text(String(localized: "Link contains no secrets. Encryption is established after the recipient accepts."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private func generateInvite() {
        isGenerating = true
        Task {
            do {
                try await mailboxManager.registerIfNeeded()
                guard let mailboxId = mailboxManager.mailboxId else { return }
                let invite = InvitePayload(
                    mailboxId: mailboxId,
                    identityKeyFingerprint: IdentityKeyManager.shared.fingerprint,
                    displayName: PeerIdentity.current.displayName,
                    expiry: Date().addingTimeInterval(24 * 60 * 60) // 24h
                )
                inviteURL = invite.toURL()
            } catch {
                // Handle error
            }
            isGenerating = false
        }
    }
}
```

**Step 3: Commit**

```bash
git add PeerDrop/Security/PairingPayload.swift PeerDrop/UI/Security/RemoteInviteView.swift
git commit -m "feat: add remote invite link generation and UI"
```

---

## Task 11: ConnectionManager Remote Integration

Wire the remote communication components into ConnectionManager.

**Files:**
- Modify: `PeerDrop/Core/ConnectionManager.swift`

**Changes (surgical, minimal):**

1. Add properties:
```swift
let preKeyStore = PreKeyStore()
let mailboxManager: MailboxManager
let remoteSessionManager: RemoteSessionManager
```

2. Initialize in `init()`:
```swift
self.mailboxManager = MailboxManager(preKeyStore: preKeyStore)
self.remoteSessionManager = RemoteSessionManager(preKeyStore: preKeyStore)
```

3. Add `handleScenePhaseChange` additions:
- `.foreground`: `mailboxManager.startPolling()`, `mailboxManager.uploadPreKeysIfNeeded()`
- `.background`: `mailboxManager.stopPolling()`, `preKeyStore.flush()`

4. Add method to handle incoming remote messages:
```swift
func handleRemoteMessage(_ message: MailboxMessage) {
    // Decode, find contact, decrypt via remoteSessionManager, route to ChatManager
}
```

5. Wire `mailboxManager.onMessageReceived` to `handleRemoteMessage`

**Step 1: Commit**

```bash
git add PeerDrop/Core/ConnectionManager.swift
git commit -m "feat: integrate remote session and mailbox into ConnectionManager"
```

---

## Task 12: Full Integration Test

Run the complete test suite and verify everything works together.

**Step 1: Run full test suite**

```bash
xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' 2>&1 | grep -E '(Executed|FAIL)'
```
Expected: All tests pass, 0 failures

**Step 2: Build for release**

```bash
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -configuration Release -quiet
```
Expected: BUILD SUCCEEDED

**Step 3: Commit if fixes needed**

---

## Summary of New Files

```
PeerDrop/Security/Protocol/
  PreKeyBundle.swift              — Pre-key data models (signed + one-time)
  PreKeyStore.swift               — Local pre-key management with encrypted persistence
  X3DH.swift                      — Extended Triple Diffie-Hellman key agreement
  DoubleRatchet.swift             — Double Ratchet session (per-message forward secrecy)
  ProofOfWork.swift               — Hashcash anti-abuse computation
  RemoteSessionManager.swift      — Orchestrates X3DH + Double Ratchet for remote peers

PeerDrop/Transport/
  MailboxClient.swift             — HTTP client for v2 relay API
  MailboxManager.swift            — Mailbox lifecycle, polling, pre-key upload

PeerDrop/UI/Security/
  RemoteInviteView.swift          — Remote invite link generation UI

cloudflare-worker/src/
  index.ts                        — Extended with v2 API endpoints

Tests (new):
  PreKeyBundleTests.swift         — 6 tests
  PreKeyStoreTests.swift          — 9 tests
  X3DHTests.swift                 — 3 tests
  DoubleRatchetTests.swift        — 7 tests
  ProofOfWorkTests.swift          — 4 tests
```

## Files Modified

```
PeerDrop/Security/IdentityKeyManager.swift  — Expose agreement key for X3DH
PeerDrop/Security/PairingPayload.swift      — Add InvitePayload
PeerDrop/Core/ConnectionManager.swift       — Add remote session + mailbox integration
cloudflare-worker/src/index.ts              — v2 API endpoints
cloudflare-worker/wrangler.toml             — KV namespace for v2
```
