# v3.0 Phase 1 — Security Foundation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace ephemeral session keys with persistent Curve25519 identity keys stored in Secure Enclave, add a trust model with three levels (verified/linked/unknown), and upgrade local connections to use ECDH + AES-256-GCM with public key verification via QR code.

**Architecture:** Build a new `IdentityKeyManager` backed by Secure Enclave for persistent device identity. Create a `TrustedContactStore` that extends `DeviceRecordStore` with trust levels and public key storage. Modify `ConnectionManager` to perform key exchange during connection setup and verify against known trusted contacts. Enhance `ConnectionQRView` to encode/decode public keys for face-to-face verification.

**Tech Stack:** CryptoKit (Curve25519, AES-GCM, HKDF), iOS Keychain (Secure Enclave), existing NWConnection/TLS infrastructure, existing ChatDataEncryptor pattern.

**Design Doc:** `docs/plans/2026-04-12-v3-secure-comms-design.md`

**Existing Code Context:**
- `PeerDrop/Security/CertificateManager.swift` — Current ephemeral P-256 keys, will be replaced
- `PeerDrop/Security/ChatDataEncryptor.swift` — AES-256-GCM at-rest encryption, reuse pattern
- `PeerDrop/Security/TLSConfiguration.swift` — TLS 1.2+ with TOFU pinning, will be enhanced
- `PeerDrop/Core/DeviceRecordStore.swift` — Peer storage, will be extended
- `PeerDrop/Core/DeviceRecord.swift` — Peer model, will be extended
- `PeerDrop/Core/ConnectionManager.swift` — ~3000 lines, connection lifecycle
- `PeerDrop/Core/PeerIdentity.swift` — Current identity model (id, name, fingerprint)
- `PeerDrop/UI/Connection/ConnectionQRView.swift` — QR pairing flow
- `PeerDrop/Pet/Engine/PetEngine.swift` — Event hooks (onPeerConnected, handlePetMeeting)
- Build: `xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet`
- Test: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest'`
- After adding new .swift files: `xcodegen generate`

---

## Task 1: IdentityKeyManager — Persistent Curve25519 Device Identity

Create a new manager that generates and stores a persistent Curve25519 key pair in the Secure Enclave / Keychain. This replaces the ephemeral per-session P-256 keys in `CertificateManager`.

**Files:**
- Create: `PeerDrop/Security/IdentityKeyManager.swift`
- Create: `PeerDropTests/IdentityKeyManagerTests.swift`

**Step 1: Write the failing tests**

```swift
// PeerDropTests/IdentityKeyManagerTests.swift
import XCTest
import CryptoKit
@testable import PeerDrop

final class IdentityKeyManagerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Clear any existing test keys
        IdentityKeyManager.shared.deleteIdentity()
    }

    func testGeneratesKeyPairOnFirstAccess() {
        let pubKey = IdentityKeyManager.shared.publicKey
        XCTAssertNotNil(pubKey)
        XCTAssertEqual(pubKey.rawRepresentation.count, 32) // Curve25519 = 32 bytes
    }

    func testKeyPersistsAcrossInstances() {
        let pubKey1 = IdentityKeyManager.shared.publicKey
        // Simulate a new instance by clearing cache
        IdentityKeyManager.shared.clearCache()
        let pubKey2 = IdentityKeyManager.shared.publicKey
        XCTAssertEqual(pubKey1.rawRepresentation, pubKey2.rawRepresentation)
    }

    func testFingerprintIsDeterministic() {
        let fp1 = IdentityKeyManager.shared.fingerprint
        let fp2 = IdentityKeyManager.shared.fingerprint
        XCTAssertEqual(fp1, fp2)
        XCTAssertFalse(fp1.isEmpty)
    }

    func testFingerprintFormat() {
        let fp = IdentityKeyManager.shared.fingerprint
        // Format: "XXXX XXXX XXXX XXXX XXXX" (5 groups of 4 hex chars, space-separated)
        let parts = fp.split(separator: " ")
        XCTAssertEqual(parts.count, 5)
        for part in parts {
            XCTAssertEqual(part.count, 4)
        }
    }

    func testDeleteIdentityRegeneratesNewKey() {
        let pubKey1 = IdentityKeyManager.shared.publicKey
        IdentityKeyManager.shared.deleteIdentity()
        let pubKey2 = IdentityKeyManager.shared.publicKey
        XCTAssertNotEqual(pubKey1.rawRepresentation, pubKey2.rawRepresentation)
    }

    func testSharedSecretDerivation() {
        let otherKey = Curve25519.KeyAgreement.PrivateKey()
        let sharedSecret = try? IdentityKeyManager.shared.deriveSharedSecret(
            with: otherKey.publicKey
        )
        XCTAssertNotNil(sharedSecret)
    }

    func testSignAndVerify() {
        let message = "test message".data(using: .utf8)!
        let signature = try? IdentityKeyManager.shared.sign(message)
        XCTAssertNotNil(signature)

        let pubKey = IdentityKeyManager.shared.signingPublicKey
        let isValid = IdentityKeyManager.shared.verify(
            signature: signature!,
            for: message,
            from: pubKey
        )
        XCTAssertTrue(isValid)
    }

    func testVerifyRejectsWrongMessage() {
        let message = "test message".data(using: .utf8)!
        let wrongMessage = "wrong message".data(using: .utf8)!
        let signature = try! IdentityKeyManager.shared.sign(message)

        let pubKey = IdentityKeyManager.shared.signingPublicKey
        let isValid = IdentityKeyManager.shared.verify(
            signature: signature,
            for: wrongMessage,
            from: pubKey
        )
        XCTAssertFalse(isValid)
    }

    func testPublicKeyExportImport() {
        let pubKey = IdentityKeyManager.shared.publicKey
        let exported = pubKey.rawRepresentation

        let imported = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: exported)
        XCTAssertNotNil(imported)
        XCTAssertEqual(imported?.rawRepresentation, pubKey.rawRepresentation)
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/IdentityKeyManagerTests 2>&1 | tail -20`
Expected: FAIL — `IdentityKeyManager` not found

**Step 3: Write the implementation**

```swift
// PeerDrop/Security/IdentityKeyManager.swift
import Foundation
import CryptoKit

/// Manages a persistent Curve25519 device identity key pair.
/// Private keys are stored in the iOS Keychain and never leave the device.
final class IdentityKeyManager {

    static let shared = IdentityKeyManager()

    private let keychainService = "com.peerdrop.identity"
    private let agreementKeyAccount = "curve25519-agreement"
    private let signingKeyAccount = "ed25519-signing"
    private let lock = NSLock()
    private var cachedAgreementKey: Curve25519.KeyAgreement.PrivateKey?
    private var cachedSigningKey: Curve25519.Signing.PrivateKey?

    private init() {}

    // MARK: - Key Agreement (Curve25519 for ECDH)

    var publicKey: Curve25519.KeyAgreement.PublicKey {
        agreementPrivateKey.publicKey
    }

    /// Human-readable fingerprint: "A1B2 C3D4 E5F6 G7H8 I9J0"
    var fingerprint: String {
        let hash = SHA256.hash(data: publicKey.rawRepresentation)
        let hex = hash.prefix(10).map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: 20, by: 4).map { i in
            let start = hex.index(hex.startIndex, offsetBy: i)
            let end = hex.index(start, offsetBy: 4)
            return String(hex[start..<end])
        }.joined(separator: " ")
    }

    func deriveSharedSecret(
        with peerPublicKey: Curve25519.KeyAgreement.PublicKey
    ) throws -> SharedSecret {
        try agreementPrivateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
    }

    // MARK: - Signing (Ed25519)

    var signingPublicKey: Curve25519.Signing.PublicKey {
        signingPrivateKey.publicKey
    }

    func sign(_ data: Data) throws -> Data {
        let signature = try signingPrivateKey.signature(for: data)
        return signature
    }

    func verify(signature: Data, for data: Data, from publicKey: Curve25519.Signing.PublicKey) -> Bool {
        return publicKey.isValidSignature(signature, for: data)
    }

    // MARK: - Lifecycle

    func deleteIdentity() {
        lock.lock()
        defer { lock.unlock() }
        deleteFromKeychain(account: agreementKeyAccount)
        deleteFromKeychain(account: signingKeyAccount)
        cachedAgreementKey = nil
        cachedSigningKey = nil
    }

    func clearCache() {
        lock.lock()
        defer { lock.unlock() }
        cachedAgreementKey = nil
        cachedSigningKey = nil
    }

    // MARK: - Private Key Access

    private var agreementPrivateKey: Curve25519.KeyAgreement.PrivateKey {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cachedAgreementKey { return cached }
        if let loaded = loadAgreementKey() {
            cachedAgreementKey = loaded
            return loaded
        }
        let newKey = Curve25519.KeyAgreement.PrivateKey()
        saveToKeychain(data: newKey.rawRepresentation, account: agreementKeyAccount)
        cachedAgreementKey = newKey
        return newKey
    }

    private var signingPrivateKey: Curve25519.Signing.PrivateKey {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cachedSigningKey { return cached }
        if let loaded = loadSigningKey() {
            cachedSigningKey = loaded
            return loaded
        }
        let newKey = Curve25519.Signing.PrivateKey()
        saveToKeychain(data: newKey.rawRepresentation, account: signingKeyAccount)
        cachedSigningKey = newKey
        return newKey
    }

    // MARK: - Keychain Operations

    private func loadAgreementKey() -> Curve25519.KeyAgreement.PrivateKey? {
        guard let data = loadFromKeychain(account: agreementKeyAccount) else { return nil }
        return try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
    }

    private func loadSigningKey() -> Curve25519.Signing.PrivateKey? {
        guard let data = loadFromKeychain(account: signingKeyAccount) else { return nil }
        return try? Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }

    private func saveToKeychain(data: Data, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    private func loadFromKeychain(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private func deleteFromKeychain(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
```

**Step 4: Regenerate project and run tests**

Run: `xcodegen generate && xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/IdentityKeyManagerTests 2>&1 | tail -20`
Expected: ALL PASS

**Step 5: Commit**

```bash
git add PeerDrop/Security/IdentityKeyManager.swift PeerDropTests/IdentityKeyManagerTests.swift
git commit -m "feat: add IdentityKeyManager with persistent Curve25519 keys in Keychain"
```

---

## Task 2: TrustLevel Model & TrustedContact

Create the trust level enum and TrustedContact data model that extends the existing DeviceRecord concept.

**Files:**
- Create: `PeerDrop/Security/TrustLevel.swift`
- Create: `PeerDrop/Security/TrustedContact.swift`
- Create: `PeerDropTests/TrustedContactTests.swift`

**Step 1: Write the failing tests**

```swift
// PeerDropTests/TrustedContactTests.swift
import XCTest
import CryptoKit
@testable import PeerDrop

final class TrustedContactTests: XCTestCase {

    func testTrustLevelOrdering() {
        XCTAssertTrue(TrustLevel.verified.isAtLeast(.linked))
        XCTAssertTrue(TrustLevel.verified.isAtLeast(.unknown))
        XCTAssertTrue(TrustLevel.linked.isAtLeast(.unknown))
        XCTAssertFalse(TrustLevel.unknown.isAtLeast(.linked))
        XCTAssertFalse(TrustLevel.linked.isAtLeast(.verified))
    }

    func testTrustedContactCreation() {
        let keyPair = Curve25519.KeyAgreement.PrivateKey()
        let contact = TrustedContact(
            id: UUID(),
            displayName: "Bob",
            identityPublicKey: keyPair.publicKey.rawRepresentation,
            trustLevel: .verified,
            firstConnected: Date()
        )
        XCTAssertEqual(contact.displayName, "Bob")
        XCTAssertEqual(contact.trustLevel, .verified)
        XCTAssertFalse(contact.isBlocked)
        XCTAssertNil(contact.mailboxId)
        XCTAssertNil(contact.userId)
    }

    func testKeyFingerprint() {
        let keyPair = Curve25519.KeyAgreement.PrivateKey()
        let contact = TrustedContact(
            id: UUID(),
            displayName: "Bob",
            identityPublicKey: keyPair.publicKey.rawRepresentation,
            trustLevel: .verified,
            firstConnected: Date()
        )
        let fp = contact.keyFingerprint
        let parts = fp.split(separator: " ")
        XCTAssertEqual(parts.count, 5)
    }

    func testCodableRoundTrip() throws {
        let keyPair = Curve25519.KeyAgreement.PrivateKey()
        let original = TrustedContact(
            id: UUID(),
            displayName: "Carol",
            identityPublicKey: keyPair.publicKey.rawRepresentation,
            trustLevel: .linked,
            firstConnected: Date(),
            lastVerified: nil,
            mailboxId: "mbx_test",
            userId: nil,
            isBlocked: false
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TrustedContact.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.displayName, original.displayName)
        XCTAssertEqual(decoded.identityPublicKey, original.identityPublicKey)
        XCTAssertEqual(decoded.trustLevel, original.trustLevel)
        XCTAssertEqual(decoded.mailboxId, original.mailboxId)
    }

    func testKeyChangeDetection() {
        let oldKey = Curve25519.KeyAgreement.PrivateKey()
        let newKey = Curve25519.KeyAgreement.PrivateKey()
        let contact = TrustedContact(
            id: UUID(),
            displayName: "Bob",
            identityPublicKey: oldKey.publicKey.rawRepresentation,
            trustLevel: .verified,
            firstConnected: Date()
        )
        XCTAssertTrue(contact.matchesKey(oldKey.publicKey.rawRepresentation))
        XCTAssertFalse(contact.matchesKey(newKey.publicKey.rawRepresentation))
    }

    func testTrustLevelSFSymbol() {
        XCTAssertEqual(TrustLevel.verified.sfSymbol, "lock.shield")
        XCTAssertEqual(TrustLevel.linked.sfSymbol, "link.circle")
        XCTAssertEqual(TrustLevel.unknown.sfSymbol, "exclamationmark.triangle")
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/TrustedContactTests 2>&1 | tail -20`
Expected: FAIL — types not found

**Step 3: Write the implementation**

```swift
// PeerDrop/Security/TrustLevel.swift
import Foundation

enum TrustLevel: String, Codable, Comparable {
    case verified   // lock.shield — face-to-face QR verified
    case linked     // link.circle — remote connected, not verified
    case unknown    // exclamationmark.triangle — unknown source

    var sfSymbol: String {
        switch self {
        case .verified: return "lock.shield"
        case .linked: return "link.circle"
        case .unknown: return "exclamationmark.triangle"
        }
    }

    var localizedLabel: String {
        switch self {
        case .verified: return String(localized: "Verified")
        case .linked: return String(localized: "Linked")
        case .unknown: return String(localized: "Unknown")
        }
    }

    func isAtLeast(_ level: TrustLevel) -> Bool {
        self >= level
    }

    private var rank: Int {
        switch self {
        case .verified: return 2
        case .linked: return 1
        case .unknown: return 0
        }
    }

    static func < (lhs: TrustLevel, rhs: TrustLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}
```

```swift
// PeerDrop/Security/TrustedContact.swift
import Foundation
import CryptoKit

struct TrustedContact: Codable, Identifiable {
    let id: UUID
    var displayName: String
    var identityPublicKey: Data              // Curve25519 public key (32 bytes)
    var trustLevel: TrustLevel
    let firstConnected: Date
    var lastVerified: Date?
    var mailboxId: String?                   // Future: remote mailbox ID
    var userId: String?                      // Future: account user ID
    var isBlocked: Bool

    init(
        id: UUID = UUID(),
        displayName: String,
        identityPublicKey: Data,
        trustLevel: TrustLevel,
        firstConnected: Date = Date(),
        lastVerified: Date? = nil,
        mailboxId: String? = nil,
        userId: String? = nil,
        isBlocked: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.identityPublicKey = identityPublicKey
        self.trustLevel = trustLevel
        self.firstConnected = firstConnected
        self.lastVerified = lastVerified
        self.mailboxId = mailboxId
        self.userId = userId
        self.isBlocked = isBlocked
    }

    /// SHA-256 fingerprint of public key in "XXXX XXXX XXXX XXXX XXXX" format
    var keyFingerprint: String {
        let hash = SHA256.hash(data: identityPublicKey)
        let hex = hash.prefix(10).map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: 20, by: 4).map { i in
            let start = hex.index(hex.startIndex, offsetBy: i)
            let end = hex.index(start, offsetBy: 4)
            return String(hex[start..<end])
        }.joined(separator: " ")
    }

    /// Check if a given public key matches this contact's stored key
    func matchesKey(_ otherPublicKey: Data) -> Bool {
        identityPublicKey == otherPublicKey
    }

    /// Get CryptoKit public key object
    func cryptoPublicKey() throws -> Curve25519.KeyAgreement.PublicKey {
        try Curve25519.KeyAgreement.PublicKey(rawRepresentation: identityPublicKey)
    }
}
```

**Step 4: Regenerate project and run tests**

Run: `xcodegen generate && xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/TrustedContactTests 2>&1 | tail -20`
Expected: ALL PASS

**Step 5: Commit**

```bash
git add PeerDrop/Security/TrustLevel.swift PeerDrop/Security/TrustedContact.swift PeerDropTests/TrustedContactTests.swift
git commit -m "feat: add TrustLevel enum and TrustedContact model"
```

---

## Task 3: TrustedContactStore — Encrypted Persistence

Create a store that manages TrustedContact instances with encrypted persistence, replacing the plaintext DeviceRecord storage for trust-related data.

**Files:**
- Create: `PeerDrop/Security/TrustedContactStore.swift`
- Create: `PeerDropTests/TrustedContactStoreTests.swift`

**Step 1: Write the failing tests**

```swift
// PeerDropTests/TrustedContactStoreTests.swift
import XCTest
import CryptoKit
@testable import PeerDrop

final class TrustedContactStoreTests: XCTestCase {

    var store: TrustedContactStore!

    override func setUp() {
        super.setUp()
        store = TrustedContactStore(storageKey: "test-trusted-contacts-\(UUID().uuidString)")
    }

    override func tearDown() {
        store.removeAll()
        super.tearDown()
    }

    private func makeContact(name: String, trust: TrustLevel = .verified) -> TrustedContact {
        let key = Curve25519.KeyAgreement.PrivateKey()
        return TrustedContact(
            displayName: name,
            identityPublicKey: key.publicKey.rawRepresentation,
            trustLevel: trust
        )
    }

    func testAddAndRetrieve() {
        let contact = makeContact(name: "Alice")
        store.add(contact)
        XCTAssertEqual(store.all.count, 1)
        XCTAssertEqual(store.all.first?.displayName, "Alice")
    }

    func testFindByPublicKey() {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let contact = TrustedContact(
            displayName: "Bob",
            identityPublicKey: key.publicKey.rawRepresentation,
            trustLevel: .linked
        )
        store.add(contact)

        let found = store.find(byPublicKey: key.publicKey.rawRepresentation)
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.displayName, "Bob")
    }

    func testFindByPublicKeyReturnsNilForUnknown() {
        let unknownKey = Curve25519.KeyAgreement.PrivateKey()
        let found = store.find(byPublicKey: unknownKey.publicKey.rawRepresentation)
        XCTAssertNil(found)
    }

    func testUpdateTrustLevel() {
        let contact = makeContact(name: "Carol", trust: .linked)
        store.add(contact)

        store.updateTrustLevel(for: contact.id, to: .verified)
        let updated = store.find(byId: contact.id)
        XCTAssertEqual(updated?.trustLevel, .verified)
        XCTAssertNotNil(updated?.lastVerified)
    }

    func testBlockContact() {
        let contact = makeContact(name: "Dave")
        store.add(contact)

        store.setBlocked(contact.id, blocked: true)
        XCTAssertTrue(store.find(byId: contact.id)?.isBlocked == true)
    }

    func testRemoveContact() {
        let contact = makeContact(name: "Eve")
        store.add(contact)
        XCTAssertEqual(store.all.count, 1)

        store.remove(contact.id)
        XCTAssertEqual(store.all.count, 0)
    }

    func testDetectKeyChange() {
        let oldKey = Curve25519.KeyAgreement.PrivateKey()
        let contact = TrustedContact(
            displayName: "Frank",
            identityPublicKey: oldKey.publicKey.rawRepresentation,
            trustLevel: .verified
        )
        store.add(contact)

        let newKey = Curve25519.KeyAgreement.PrivateKey()
        let change = store.detectKeyChange(
            contactId: contact.id,
            newPublicKey: newKey.publicKey.rawRepresentation
        )
        XCTAssertTrue(change)
    }

    func testDetectKeyChangeReturnsFalseWhenSame() {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let contact = TrustedContact(
            displayName: "Grace",
            identityPublicKey: key.publicKey.rawRepresentation,
            trustLevel: .verified
        )
        store.add(contact)

        let change = store.detectKeyChange(
            contactId: contact.id,
            newPublicKey: key.publicKey.rawRepresentation
        )
        XCTAssertFalse(change)
    }

    func testNonBlockedContacts() {
        let c1 = makeContact(name: "A")
        let c2 = makeContact(name: "B")
        store.add(c1)
        store.add(c2)
        store.setBlocked(c1.id, blocked: true)

        XCTAssertEqual(store.nonBlocked.count, 1)
        XCTAssertEqual(store.nonBlocked.first?.displayName, "B")
    }

    func testPersistenceRoundTrip() {
        let key = "test-persist-\(UUID().uuidString)"
        let store1 = TrustedContactStore(storageKey: key)
        let contact = makeContact(name: "Persist")
        store1.add(contact)

        let store2 = TrustedContactStore(storageKey: key)
        XCTAssertEqual(store2.all.count, 1)
        XCTAssertEqual(store2.all.first?.displayName, "Persist")

        store1.removeAll()
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/TrustedContactStoreTests 2>&1 | tail -20`
Expected: FAIL — `TrustedContactStore` not found

**Step 3: Write the implementation**

```swift
// PeerDrop/Security/TrustedContactStore.swift
import Foundation
import Combine

final class TrustedContactStore: ObservableObject {

    @Published private(set) var contacts: [TrustedContact] = []

    private let storageKey: String
    private let encryptor = ChatDataEncryptor.shared
    private let saveDebounce = DispatchWorkItem { }
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

    func updatePublicKey(for id: UUID, newKey: Data) {
        guard let index = contacts.firstIndex(where: { $0.id == id }) else { return }
        contacts[index].identityPublicKey = newKey
        contacts[index].trustLevel = .unknown // Downgrade trust on key change
        contacts[index].lastVerified = nil
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
            // Silently fail — next save will retry
        }
    }

    func flushPendingSave() {
        pendingSave?.cancel()
        save()
    }
}
```

**Step 4: Regenerate project and run tests**

Run: `xcodegen generate && xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/TrustedContactStoreTests 2>&1 | tail -20`
Expected: ALL PASS

**Step 5: Commit**

```bash
git add PeerDrop/Security/TrustedContactStore.swift PeerDropTests/TrustedContactStoreTests.swift
git commit -m "feat: add TrustedContactStore with encrypted persistence"
```

---

## Task 4: SessionKeyManager — Per-Connection ECDH Key Derivation

Create a manager that derives per-session symmetric keys from ECDH shared secrets for encrypting local connections.

**Files:**
- Create: `PeerDrop/Security/SessionKeyManager.swift`
- Create: `PeerDropTests/SessionKeyManagerTests.swift`

**Step 1: Write the failing tests**

```swift
// PeerDropTests/SessionKeyManagerTests.swift
import XCTest
import CryptoKit
@testable import PeerDrop

final class SessionKeyManagerTests: XCTestCase {

    func testDeriveSessionKey() throws {
        let alice = Curve25519.KeyAgreement.PrivateKey()
        let bob = Curve25519.KeyAgreement.PrivateKey()

        let sessionAlice = try SessionKeyManager.deriveSessionKey(
            myPrivateKey: alice,
            peerPublicKey: bob.publicKey
        )
        let sessionBob = try SessionKeyManager.deriveSessionKey(
            myPrivateKey: bob,
            peerPublicKey: alice.publicKey
        )
        XCTAssertEqual(sessionAlice, sessionBob)
    }

    func testDifferentPeersProduceDifferentKeys() throws {
        let alice = Curve25519.KeyAgreement.PrivateKey()
        let bob = Curve25519.KeyAgreement.PrivateKey()
        let carol = Curve25519.KeyAgreement.PrivateKey()

        let keyAB = try SessionKeyManager.deriveSessionKey(
            myPrivateKey: alice,
            peerPublicKey: bob.publicKey
        )
        let keyAC = try SessionKeyManager.deriveSessionKey(
            myPrivateKey: alice,
            peerPublicKey: carol.publicKey
        )
        XCTAssertNotEqual(keyAB, keyAC)
    }

    func testEncryptDecryptRoundTrip() throws {
        let alice = Curve25519.KeyAgreement.PrivateKey()
        let bob = Curve25519.KeyAgreement.PrivateKey()

        let key = try SessionKeyManager.deriveSessionKey(
            myPrivateKey: alice,
            peerPublicKey: bob.publicKey
        )

        let plaintext = "Hello, secure world!".data(using: .utf8)!
        let encrypted = try SessionKeyManager.encrypt(plaintext, with: key)
        XCTAssertNotEqual(encrypted, plaintext)

        let decrypted = try SessionKeyManager.decrypt(encrypted, with: key)
        XCTAssertEqual(decrypted, plaintext)
    }

    func testDecryptWithWrongKeyFails() throws {
        let alice = Curve25519.KeyAgreement.PrivateKey()
        let bob = Curve25519.KeyAgreement.PrivateKey()
        let carol = Curve25519.KeyAgreement.PrivateKey()

        let keyAB = try SessionKeyManager.deriveSessionKey(
            myPrivateKey: alice,
            peerPublicKey: bob.publicKey
        )
        let keyAC = try SessionKeyManager.deriveSessionKey(
            myPrivateKey: alice,
            peerPublicKey: carol.publicKey
        )

        let plaintext = "secret".data(using: .utf8)!
        let encrypted = try SessionKeyManager.encrypt(plaintext, with: keyAB)

        XCTAssertThrowsError(try SessionKeyManager.decrypt(encrypted, with: keyAC))
    }

    func testEncryptedDataIncludesNonce() throws {
        let alice = Curve25519.KeyAgreement.PrivateKey()
        let bob = Curve25519.KeyAgreement.PrivateKey()
        let key = try SessionKeyManager.deriveSessionKey(
            myPrivateKey: alice,
            peerPublicKey: bob.publicKey
        )

        let plaintext = "same message".data(using: .utf8)!
        let enc1 = try SessionKeyManager.encrypt(plaintext, with: key)
        let enc2 = try SessionKeyManager.encrypt(plaintext, with: key)
        // Different nonces = different ciphertext
        XCTAssertNotEqual(enc1, enc2)
    }

    func testLargeDataEncryption() throws {
        let alice = Curve25519.KeyAgreement.PrivateKey()
        let bob = Curve25519.KeyAgreement.PrivateKey()
        let key = try SessionKeyManager.deriveSessionKey(
            myPrivateKey: alice,
            peerPublicKey: bob.publicKey
        )

        let plaintext = Data(repeating: 0xAB, count: 1_000_000) // 1MB
        let encrypted = try SessionKeyManager.encrypt(plaintext, with: key)
        let decrypted = try SessionKeyManager.decrypt(encrypted, with: key)
        XCTAssertEqual(decrypted, plaintext)
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/SessionKeyManagerTests 2>&1 | tail -20`
Expected: FAIL — `SessionKeyManager` not found

**Step 3: Write the implementation**

```swift
// PeerDrop/Security/SessionKeyManager.swift
import Foundation
import CryptoKit

enum SessionKeyManager {

    /// Derive a symmetric session key from ECDH shared secret.
    /// Both peers calling this with each other's public keys get the same key.
    static func deriveSessionKey(
        myPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        peerPublicKey: Curve25519.KeyAgreement.PublicKey
    ) throws -> SymmetricKey {
        let shared = try myPrivateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: "PeerDrop-Session-v3".data(using: .utf8)!,
            sharedInfo: Data(),
            outputByteCount: 32
        )
    }

    /// Encrypt data with AES-256-GCM. Output: [12-byte nonce][ciphertext][16-byte tag]
    static func encrypt(_ plaintext: Data, with key: SymmetricKey) throws -> Data {
        let sealedBox = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealedBox.combined else {
            throw CryptoError.encryptionFailed
        }
        return combined
    }

    /// Decrypt AES-256-GCM data. Input format: [12-byte nonce][ciphertext][16-byte tag]
    static func decrypt(_ ciphertext: Data, with key: SymmetricKey) throws -> Data {
        let sealedBox = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(sealedBox, using: key)
    }

    enum CryptoError: Error {
        case encryptionFailed
    }
}
```

**Step 4: Regenerate project and run tests**

Run: `xcodegen generate && xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/SessionKeyManagerTests 2>&1 | tail -20`
Expected: ALL PASS

**Step 5: Commit**

```bash
git add PeerDrop/Security/SessionKeyManager.swift PeerDropTests/SessionKeyManagerTests.swift
git commit -m "feat: add SessionKeyManager for ECDH + AES-256-GCM per-connection encryption"
```

---

## Task 5: KeyExchangeMessage — Wire Protocol for Key Exchange

Define the message types used during connection setup to exchange public keys and verify identity.

**Files:**
- Create: `PeerDrop/Security/KeyExchangeMessage.swift`
- Create: `PeerDropTests/KeyExchangeMessageTests.swift`

**Step 1: Write the failing tests**

```swift
// PeerDropTests/KeyExchangeMessageTests.swift
import XCTest
import CryptoKit
@testable import PeerDrop

final class KeyExchangeMessageTests: XCTestCase {

    func testHelloMessageCodable() throws {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let signingKey = Curve25519.Signing.PrivateKey()
        let msg = KeyExchangeMessage.hello(
            publicKey: key.publicKey.rawRepresentation,
            signingPublicKey: signingKey.publicKey.rawRepresentation,
            fingerprint: "A1B2 C3D4 E5F6 G7H8 I9J0",
            deviceName: "iPhone"
        )

        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(KeyExchangeMessage.self, from: data)

        if case .hello(let pk, let spk, let fp, let name) = decoded {
            XCTAssertEqual(pk, key.publicKey.rawRepresentation)
            XCTAssertEqual(spk, signingKey.publicKey.rawRepresentation)
            XCTAssertEqual(fp, "A1B2 C3D4 E5F6 G7H8 I9J0")
            XCTAssertEqual(name, "iPhone")
        } else {
            XCTFail("Expected .hello")
        }
    }

    func testVerifyMessageCodable() throws {
        let nonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let msg = KeyExchangeMessage.verify(nonce: nonce)
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(KeyExchangeMessage.self, from: data)

        if case .verify(let n) = decoded {
            XCTAssertEqual(n, nonce)
        } else {
            XCTFail("Expected .verify")
        }
    }

    func testConfirmMessageCodable() throws {
        let sig = Data((0..<64).map { _ in UInt8.random(in: 0...255) })
        let msg = KeyExchangeMessage.confirm(signature: sig)
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(KeyExchangeMessage.self, from: data)

        if case .confirm(let s) = decoded {
            XCTAssertEqual(s, sig)
        } else {
            XCTFail("Expected .confirm")
        }
    }

    func testKeyChangeMessageCodable() throws {
        let oldFp = "A1B2 C3D4 E5F6 G7H8 I9J0"
        let newKey = Data(repeating: 0xAA, count: 32)
        let msg = KeyExchangeMessage.keyChanged(
            oldFingerprint: oldFp,
            newPublicKey: newKey
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(KeyExchangeMessage.self, from: data)

        if case .keyChanged(let ofp, let npk) = decoded {
            XCTAssertEqual(ofp, oldFp)
            XCTAssertEqual(npk, newKey)
        } else {
            XCTFail("Expected .keyChanged")
        }
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/KeyExchangeMessageTests 2>&1 | tail -20`
Expected: FAIL — `KeyExchangeMessage` not found

**Step 3: Write the implementation**

```swift
// PeerDrop/Security/KeyExchangeMessage.swift
import Foundation

/// Messages exchanged during the initial key exchange handshake.
/// Sent over the existing PeerMessage transport before the encrypted session begins.
enum KeyExchangeMessage: Codable {
    /// Step 1: Both peers send their public keys and device info
    case hello(
        publicKey: Data,
        signingPublicKey: Data,
        fingerprint: String,
        deviceName: String
    )

    /// Step 2: One peer sends a random nonce for the other to sign (proves key ownership)
    case verify(nonce: Data)

    /// Step 3: Peer signs the nonce with their signing key and returns the signature
    case confirm(signature: Data)

    /// Alert: Peer's key has changed since last connection
    case keyChanged(oldFingerprint: String, newPublicKey: Data)

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case type, publicKey, signingPublicKey, fingerprint, deviceName
        case nonce, signature, oldFingerprint, newPublicKey
    }

    private enum MessageType: String, Codable {
        case hello, verify, confirm, keyChanged
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let pk, let spk, let fp, let name):
            try container.encode(MessageType.hello, forKey: .type)
            try container.encode(pk, forKey: .publicKey)
            try container.encode(spk, forKey: .signingPublicKey)
            try container.encode(fp, forKey: .fingerprint)
            try container.encode(name, forKey: .deviceName)
        case .verify(let nonce):
            try container.encode(MessageType.verify, forKey: .type)
            try container.encode(nonce, forKey: .nonce)
        case .confirm(let sig):
            try container.encode(MessageType.confirm, forKey: .type)
            try container.encode(sig, forKey: .signature)
        case .keyChanged(let oldFp, let newPk):
            try container.encode(MessageType.keyChanged, forKey: .type)
            try container.encode(oldFp, forKey: .oldFingerprint)
            try container.encode(newPk, forKey: .newPublicKey)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(MessageType.self, forKey: .type)
        switch type {
        case .hello:
            self = .hello(
                publicKey: try container.decode(Data.self, forKey: .publicKey),
                signingPublicKey: try container.decode(Data.self, forKey: .signingPublicKey),
                fingerprint: try container.decode(String.self, forKey: .fingerprint),
                deviceName: try container.decode(String.self, forKey: .deviceName)
            )
        case .verify:
            self = .verify(nonce: try container.decode(Data.self, forKey: .nonce))
        case .confirm:
            self = .confirm(signature: try container.decode(Data.self, forKey: .signature))
        case .keyChanged:
            self = .keyChanged(
                oldFingerprint: try container.decode(String.self, forKey: .oldFingerprint),
                newPublicKey: try container.decode(Data.self, forKey: .newPublicKey)
            )
        }
    }
}
```

**Step 4: Regenerate project and run tests**

Run: `xcodegen generate && xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/KeyExchangeMessageTests 2>&1 | tail -20`
Expected: ALL PASS

**Step 5: Commit**

```bash
git add PeerDrop/Security/KeyExchangeMessage.swift PeerDropTests/KeyExchangeMessageTests.swift
git commit -m "feat: add KeyExchangeMessage wire protocol for identity handshake"
```

---

## Task 6: Integrate IdentityKeyManager into PeerIdentity

Update the existing `PeerIdentity` to use the new persistent identity keys instead of ephemeral session keys.

**Files:**
- Modify: `PeerDrop/Core/PeerIdentity.swift`
- Create: `PeerDropTests/PeerIdentitySecurityTests.swift`

**Step 1: Read the current PeerIdentity**

Run: Read `PeerDrop/Core/PeerIdentity.swift` to understand its current structure.

The existing `PeerIdentity` has:
- `id: String` (stable UUID)
- `displayName: String`
- `certificateFingerprint: String?`

**Step 2: Write the failing tests**

```swift
// PeerDropTests/PeerIdentitySecurityTests.swift
import XCTest
@testable import PeerDrop

final class PeerIdentitySecurityTests: XCTestCase {

    func testPeerIdentityIncludesIdentityPublicKey() {
        let identity = PeerIdentity.current
        XCTAssertNotNil(identity.identityPublicKey)
        XCTAssertEqual(identity.identityPublicKey?.count, 32) // Curve25519
    }

    func testPeerIdentityIncludesFingerprint() {
        let identity = PeerIdentity.current
        XCTAssertNotNil(identity.identityFingerprint)
        let parts = identity.identityFingerprint!.split(separator: " ")
        XCTAssertEqual(parts.count, 5)
    }

    func testPeerIdentityPublicKeyIsPersistent() {
        let pk1 = PeerIdentity.current.identityPublicKey
        let pk2 = PeerIdentity.current.identityPublicKey
        XCTAssertEqual(pk1, pk2)
    }
}
```

**Step 3: Run tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/PeerIdentitySecurityTests 2>&1 | tail -20`
Expected: FAIL — properties not found

**Step 4: Modify PeerIdentity to add new properties**

Add to `PeerIdentity`:

```swift
/// Curve25519 public key for E2E encryption (32 bytes, persistent)
var identityPublicKey: Data? {
    IdentityKeyManager.shared.publicKey.rawRepresentation
}

/// Human-readable fingerprint of the identity public key
var identityFingerprint: String? {
    IdentityKeyManager.shared.fingerprint
}
```

Keep all existing properties and `Codable` conformance unchanged. The new properties are computed, not stored, so they don't affect serialization.

**Step 5: Run tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/PeerIdentitySecurityTests 2>&1 | tail -20`
Expected: ALL PASS

**Step 6: Run full test suite to check for regressions**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' 2>&1 | tail -30`
Expected: ALL existing tests still pass

**Step 7: Commit**

```bash
git add PeerDrop/Core/PeerIdentity.swift PeerDropTests/PeerIdentitySecurityTests.swift
git commit -m "feat: integrate IdentityKeyManager into PeerIdentity"
```

---

## Task 7: QR Code Pairing — Encode/Decode Public Keys

Enhance `ConnectionQRView` to include the device's public key and fingerprint in QR codes, and add a verification confirmation screen.

**Files:**
- Create: `PeerDrop/Security/PairingPayload.swift`
- Create: `PeerDropTests/PairingPayloadTests.swift`
- Modify: `PeerDrop/UI/Connection/ConnectionQRView.swift` (later, after payload is tested)

**Step 1: Write the failing tests**

```swift
// PeerDropTests/PairingPayloadTests.swift
import XCTest
import CryptoKit
@testable import PeerDrop

final class PairingPayloadTests: XCTestCase {

    func testEncodeToURL() {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let payload = PairingPayload(
            publicKey: key.publicKey.rawRepresentation,
            signingPublicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
            fingerprint: "A1B2 C3D4 E5F6 G7H8 I9J0",
            deviceName: "Test iPhone",
            localAddress: "192.168.1.100:8765",
            relayCode: "ABCDEF"
        )

        let url = payload.toURL()
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.scheme, "peerdrop")
        XCTAssertEqual(url?.host, "pair")
        XCTAssertNotNil(url?.queryItems?["pk"])
        XCTAssertNotNil(url?.queryItems?["spk"])
        XCTAssertNotNil(url?.queryItems?["fp"])
        XCTAssertEqual(url?.queryItems?["name"], "Test iPhone")
    }

    func testDecodeFromURL() throws {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let signingKey = Curve25519.Signing.PrivateKey()
        let original = PairingPayload(
            publicKey: key.publicKey.rawRepresentation,
            signingPublicKey: signingKey.publicKey.rawRepresentation,
            fingerprint: "A1B2 C3D4 E5F6 G7H8 I9J0",
            deviceName: "Test iPhone",
            localAddress: "192.168.1.100:8765",
            relayCode: "ABCDEF"
        )

        let url = original.toURL()!
        let decoded = try PairingPayload(from: url)
        XCTAssertEqual(decoded.publicKey, original.publicKey)
        XCTAssertEqual(decoded.signingPublicKey, original.signingPublicKey)
        XCTAssertEqual(decoded.fingerprint, original.fingerprint)
        XCTAssertEqual(decoded.deviceName, original.deviceName)
        XCTAssertEqual(decoded.localAddress, original.localAddress)
        XCTAssertEqual(decoded.relayCode, original.relayCode)
    }

    func testInvalidURLThrows() {
        let url = URL(string: "https://example.com")!
        XCTAssertThrowsError(try PairingPayload(from: url))
    }

    func testSafetyNumberGeneration() {
        let keyA = Curve25519.KeyAgreement.PrivateKey()
        let keyB = Curve25519.KeyAgreement.PrivateKey()

        let num1 = PairingPayload.safetyNumber(
            myPublicKey: keyA.publicKey.rawRepresentation,
            peerPublicKey: keyB.publicKey.rawRepresentation
        )
        let num2 = PairingPayload.safetyNumber(
            myPublicKey: keyB.publicKey.rawRepresentation,
            peerPublicKey: keyA.publicKey.rawRepresentation
        )
        // Safety number is the same regardless of order
        XCTAssertEqual(num1, num2)

        // Format: "XXXXX XXXXX" (two groups of 5 digits)
        let parts = num1.split(separator: " ")
        XCTAssertEqual(parts.count, 2)
        for part in parts {
            XCTAssertEqual(part.count, 5)
        }
    }
}

// Helper for URL query item access
private extension URL {
    var queryItems: [String: String]? {
        guard let components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              let items = components.queryItems else { return nil }
        return Dictionary(uniqueKeysWithValues: items.compactMap { item in
            item.value.map { (item.name, $0) }
        })
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/PairingPayloadTests 2>&1 | tail -20`
Expected: FAIL — `PairingPayload` not found

**Step 3: Write the implementation**

```swift
// PeerDrop/Security/PairingPayload.swift
import Foundation
import CryptoKit

/// Payload encoded in QR codes for face-to-face pairing.
/// Contains public keys and connection info, no secrets.
struct PairingPayload {
    let publicKey: Data                 // Curve25519 agreement public key (32 bytes)
    let signingPublicKey: Data          // Ed25519 signing public key (32 bytes)
    let fingerprint: String             // Human-readable fingerprint
    let deviceName: String
    let localAddress: String?           // IP:port for local connection
    let relayCode: String?              // Relay room code

    func toURL() -> URL? {
        var components = URLComponents()
        components.scheme = "peerdrop"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "pk", value: publicKey.base64EncodedString()),
            URLQueryItem(name: "spk", value: signingPublicKey.base64EncodedString()),
            URLQueryItem(name: "fp", value: fingerprint),
            URLQueryItem(name: "name", value: deviceName),
        ]
        if let local = localAddress {
            components.queryItems?.append(URLQueryItem(name: "local", value: local))
        }
        if let relay = relayCode {
            components.queryItems?.append(URLQueryItem(name: "relay", value: relay))
        }
        return components.url
    }

    init(
        publicKey: Data,
        signingPublicKey: Data,
        fingerprint: String,
        deviceName: String,
        localAddress: String? = nil,
        relayCode: String? = nil
    ) {
        self.publicKey = publicKey
        self.signingPublicKey = signingPublicKey
        self.fingerprint = fingerprint
        self.deviceName = deviceName
        self.localAddress = localAddress
        self.relayCode = relayCode
    }

    init(from url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "peerdrop",
              components.host == "pair",
              let items = components.queryItems else {
            throw PairingError.invalidURL
        }

        let dict = Dictionary(uniqueKeysWithValues: items.compactMap { item in
            item.value.map { (item.name, $0) }
        })

        guard let pkBase64 = dict["pk"],
              let pk = Data(base64Encoded: pkBase64),
              let spkBase64 = dict["spk"],
              let spk = Data(base64Encoded: spkBase64),
              let fp = dict["fp"],
              let name = dict["name"] else {
            throw PairingError.missingFields
        }

        self.publicKey = pk
        self.signingPublicKey = spk
        self.fingerprint = fp
        self.deviceName = name
        self.localAddress = dict["local"]
        self.relayCode = dict["relay"]
    }

    /// Generate a safety number that both peers can compare.
    /// Ordering is canonical (sorted) so both sides get the same result.
    static func safetyNumber(myPublicKey: Data, peerPublicKey: Data) -> String {
        let sorted = [myPublicKey, peerPublicKey].sorted { $0.lexicographicallyPrecedes($1) }
        var combined = Data()
        combined.append(sorted[0])
        combined.append(sorted[1])
        let hash = SHA256.hash(data: combined)
        let bytes = Array(hash)
        let num1 = (Int(bytes[0]) << 8 | Int(bytes[1])) % 100000
        let num2 = (Int(bytes[2]) << 8 | Int(bytes[3])) % 100000
        return String(format: "%05d %05d", num1, num2)
    }

    enum PairingError: Error {
        case invalidURL
        case missingFields
    }
}
```

**Step 4: Regenerate project and run tests**

Run: `xcodegen generate && xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/PairingPayloadTests 2>&1 | tail -20`
Expected: ALL PASS

**Step 5: Commit**

```bash
git add PeerDrop/Security/PairingPayload.swift PeerDropTests/PairingPayloadTests.swift
git commit -m "feat: add PairingPayload for QR code public key exchange"
```

---

## Task 8: KeyChangeAlert View — Full-Screen Key Change Warning

Create the UI for key change detection — a full-screen warning with pet reaction, as designed in the design doc.

**Files:**
- Create: `PeerDrop/UI/Security/KeyChangeAlertView.swift`
- Create: `PeerDrop/UI/Security/TrustBadgeView.swift`

**Step 1: Write TrustBadgeView (small reusable component)**

```swift
// PeerDrop/UI/Security/TrustBadgeView.swift
import SwiftUI

/// Displays a trust level icon + label. Used in contact rows and headers.
struct TrustBadgeView: View {
    let trustLevel: TrustLevel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: trustLevel.sfSymbol)
                .font(.caption)
            Text(trustLevel.localizedLabel)
                .font(.caption)
        }
        .foregroundStyle(color)
    }

    private var color: Color {
        switch trustLevel {
        case .verified: return .green
        case .linked: return .blue
        case .unknown: return .orange
        }
    }
}
```

**Step 2: Write KeyChangeAlertView**

```swift
// PeerDrop/UI/Security/KeyChangeAlertView.swift
import SwiftUI

/// Full-screen alert shown when a known contact's encryption key has changed.
struct KeyChangeAlertView: View {
    let contactName: String
    let oldFingerprint: String
    let newFingerprint: String
    let onBlock: () -> Void
    let onAccept: () -> Void
    let onVerifyLater: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "exclamationmark.shield")
                .font(.system(size: 64))
                .foregroundStyle(.orange)

            Text("Security Warning")
                .font(.title.bold())

            Text("\(contactName)'s encryption key has changed.")
                .font(.body)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 12) {
                Text("This could be because:")
                    .font(.subheadline.bold())
                reasonRow(icon: "iphone", text: String(localized: "\(contactName) got a new device"))
                reasonRow(icon: "arrow.clockwise", text: String(localized: "\(contactName) reinstalled PeerDrop"))
                reasonRow(icon: "exclamationmark.triangle", text: String(localized: "Someone is trying to impersonate \(contactName)"))
            }
            .padding()
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 8) {
                fingerprintRow(label: String(localized: "Previous"), value: oldFingerprint)
                fingerprintRow(label: String(localized: "New"), value: newFingerprint)
            }
            .padding()
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Spacer()

            VStack(spacing: 12) {
                Button(action: onBlock) {
                    Label(String(localized: "Block This Contact"), systemImage: "hand.raised")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

                Button(action: onAccept) {
                    Label(String(localized: "Accept New Key"), systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(action: onVerifyLater) {
                    Label(String(localized: "Verify Next Time"), systemImage: "clock")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
            }
        }
        .padding()
    }

    private func reasonRow(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.subheadline)
        }
    }

    private func fingerprintRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.caption, design: .monospaced))
        }
    }
}
```

**Step 3: Regenerate project and build**

Run: `xcodegen generate && xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add PeerDrop/UI/Security/KeyChangeAlertView.swift PeerDrop/UI/Security/TrustBadgeView.swift
git commit -m "feat: add KeyChangeAlertView and TrustBadgeView UI components"
```

---

## Task 9: VerificationView — Face-to-Face Safety Number Confirmation

Create the screen shown during QR pairing where both peers compare safety numbers and see their pets interact.

**Files:**
- Create: `PeerDrop/UI/Security/VerificationView.swift`

**Step 1: Write the implementation**

```swift
// PeerDrop/UI/Security/VerificationView.swift
import SwiftUI

/// Shown after QR scan during face-to-face pairing.
/// Both peers see the same safety number and confirm it matches.
struct VerificationView: View {
    let peerName: String
    let safetyNumber: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "lock.shield")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("Verify Identity")
                .font(.title2.bold())

            Text(String(localized: "Confirm the safety number matches \(peerName)'s screen"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text(safetyNumber)
                .font(.system(size: 36, weight: .bold, design: .monospaced))
                .tracking(4)
                .padding()
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            // Pet interaction area (placeholder — will be connected to PetEngine)
            HStack(spacing: 32) {
                VStack {
                    Image(systemName: "heart")
                        .font(.title)
                        .foregroundStyle(.pink)
                    Text(String(localized: "Your Pet"))
                        .font(.caption)
                }
                Image(systemName: "arrow.left.arrow.right")
                    .foregroundStyle(.secondary)
                VStack {
                    Image(systemName: "heart")
                        .font(.title)
                        .foregroundStyle(.pink)
                    Text(peerName)
                        .font(.caption)
                }
            }
            .padding()

            Spacer()

            VStack(spacing: 12) {
                Button(action: onConfirm) {
                    Label(String(localized: "Numbers Match"), systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Button(action: onCancel) {
                    Label(String(localized: "Cancel"), systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
            }
        }
        .padding()
    }
}
```

**Step 2: Regenerate project and build**

Run: `xcodegen generate && xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add PeerDrop/UI/Security/VerificationView.swift
git commit -m "feat: add VerificationView for face-to-face safety number confirmation"
```

---

## Task 10: SecurityDashboardView — Pet-Integrated Security Overview

Create the pet security dashboard that shows trust status in a user-friendly way.

**Files:**
- Create: `PeerDrop/UI/Security/SecurityDashboardView.swift`

**Step 1: Write the implementation**

```swift
// PeerDrop/UI/Security/SecurityDashboardView.swift
import SwiftUI

/// Pet-narrated security dashboard. Shows overall security status
/// with pet personality — users understand security through pet mood.
struct SecurityDashboardView: View {
    @ObservedObject var contactStore: TrustedContactStore

    var body: some View {
        List {
            Section {
                protectionMeter
            }

            Section {
                statusRow(
                    icon: "lock",
                    label: String(localized: "Keys stored on device"),
                    isGood: true
                )
                statusRow(
                    icon: "lock.shield",
                    label: String(localized: "\(verifiedCount) verified contacts"),
                    isGood: verifiedCount > 0
                )
                if unverifiedCount > 0 {
                    statusRow(
                        icon: "exclamationmark.triangle",
                        label: String(localized: "\(unverifiedCount) contacts not yet verified"),
                        isGood: false
                    )
                }
                statusRow(
                    icon: "lock",
                    label: String(localized: "All conversations encrypted"),
                    isGood: true
                )
            } header: {
                Text("Security Status")
            }

            if !contactStore.nonBlocked.isEmpty {
                Section {
                    ForEach(contactStore.nonBlocked) { contact in
                        HStack {
                            Text(contact.displayName)
                            Spacer()
                            TrustBadgeView(trustLevel: contact.trustLevel)
                        }
                    }
                } header: {
                    Text("Contacts")
                }
            }

            Section {
                HStack {
                    Text("Identity Fingerprint")
                        .font(.subheadline)
                    Spacer()
                    Text(IdentityKeyManager.shared.fingerprint)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Your Device")
            }
        }
        .navigationTitle(String(localized: "Security"))
    }

    private var verifiedCount: Int {
        contactStore.contacts.filter { $0.trustLevel == .verified && !$0.isBlocked }.count
    }

    private var unverifiedCount: Int {
        contactStore.contacts.filter { $0.trustLevel != .verified && !$0.isBlocked }.count
    }

    private var protectionScore: Double {
        let total = contactStore.nonBlocked.count
        guard total > 0 else { return 1.0 }
        let verified = Double(verifiedCount)
        return (verified / Double(total)) * 0.7 + 0.3 // Base 30% for having encryption
    }

    private var protectionMeter: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.title)
                    .foregroundStyle(protectionColor)
                VStack(alignment: .leading) {
                    Text("Protection Level")
                        .font(.headline)
                    Text(protectionLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            ProgressView(value: protectionScore)
                .tint(protectionColor)
        }
        .padding(.vertical, 4)
    }

    private var protectionColor: Color {
        if protectionScore >= 0.8 { return .green }
        if protectionScore >= 0.5 { return .orange }
        return .red
    }

    private var protectionLabel: String {
        if protectionScore >= 0.8 { return String(localized: "Excellent") }
        if protectionScore >= 0.5 { return String(localized: "Good — verify remaining contacts") }
        return String(localized: "Needs attention")
    }

    private func statusRow(icon: String, label: String, isGood: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isGood ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundStyle(isGood ? .green : .orange)
            Text(label)
                .font(.subheadline)
        }
    }
}
```

**Step 2: Regenerate project and build**

Run: `xcodegen generate && xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add PeerDrop/UI/Security/SecurityDashboardView.swift
git commit -m "feat: add SecurityDashboardView with protection meter and trust overview"
```

---

## Task 11: Integration — Wire TrustedContactStore into ConnectionManager

This is the integration task: connect the new security components to the existing connection flow. This is the most delicate task — it modifies the 3000-line ConnectionManager.

**Files:**
- Modify: `PeerDrop/Core/ConnectionManager.swift`
- Modify: `PeerDrop/Core/PeerIdentity.swift` (add hello message creation)

**Step 1: Read ConnectionManager's connection flow**

Read these sections of `ConnectionManager.swift`:
- Class properties (top ~100 lines) — to understand where to add `trustedContactStore`
- Connection establishment (`acceptPeer`, `connectToPeer`) — to understand where key exchange happens
- Message receiving (`handleIncomingMessage`) — to understand where to intercept key exchange messages

**Step 2: Add TrustedContactStore as a property**

At the top of `ConnectionManager`, among the existing `let` properties (alongside `deviceRecordStore`, `chatManager`):

```swift
let trustedContactStore = TrustedContactStore()
```

**Step 3: Add key exchange to connection setup**

After a connection is established (state transitions to `.connected` or `.established`), add a key exchange step:

1. Send a `.hello` `KeyExchangeMessage` containing our public key, signing key, fingerprint, and device name
2. When receiving a `.hello` from the peer, check `trustedContactStore`:
   - If peer's public key is known and matches → trust level stays the same, proceed
   - If peer's public key is known but CHANGED → trigger `KeyChangeAlertView`
   - If peer's public key is unknown → create new contact with `.unknown` trust level
3. After `.hello` exchange, derive session key with `SessionKeyManager`

**Step 4: Add key exchange message type to PeerMessage**

In the existing `PeerMessage` type enum, add a new case for key exchange:

```swift
case keyExchange  // New: carries KeyExchangeMessage payload
```

**Step 5: Build and run full test suite**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' 2>&1 | tail -30`
Expected: ALL PASS (no regressions)

**Step 6: Commit**

```bash
git add PeerDrop/Core/ConnectionManager.swift PeerDrop/Core/PeerIdentity.swift
git commit -m "feat: integrate key exchange and TrustedContactStore into ConnectionManager"
```

---

## Task 12: Integration — Update QR Pairing Flow

Update `ConnectionQRView` to use the new `PairingPayload` format that includes public keys.

**Files:**
- Modify: `PeerDrop/UI/Connection/ConnectionQRView.swift`

**Step 1: Read current QR generation code**

Read `ConnectionQRView.swift` to understand the current URL format:
```
peerdrop://smart?ts=IP:PORT&local=IP:PORT&relay=CODE&name=NAME
```

**Step 2: Update QR content to include public key**

Change the QR URL generation to use `PairingPayload.toURL()`, which adds `pk`, `spk`, and `fp` parameters while keeping existing `local` and `relay` parameters.

**Step 3: Update QR scanning to decode public key**

When scanning a QR code, parse it as `PairingPayload(from: url)`. On successful decode:
1. Show `VerificationView` with the safety number
2. On confirm → create `TrustedContact` with `.verified` trust level
3. Proceed with existing connection flow

**Step 4: Build and test**

Run: `xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

**Step 5: Commit**

```bash
git add PeerDrop/UI/Connection/ConnectionQRView.swift
git commit -m "feat: include public key in QR pairing, show safety number verification"
```

---

## Task 13: Full Integration Test & Regression Check

Run the complete test suite and verify everything works together.

**Step 1: Run full test suite**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' 2>&1 | grep -E '(Test Suite|Tests|Passed|Failed)'`
Expected: All tests pass, including new tests

**Step 2: Build for release**

Run: `xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -configuration Release -quiet 2>&1 | tail -10`
Expected: BUILD SUCCEEDED (no warnings in new code)

**Step 3: Final commit if any fixes needed**

```bash
git add -A
git commit -m "fix: address integration test issues from Phase 1 security foundation"
```

---

## Summary of New Files Created

```
PeerDrop/Security/
  IdentityKeyManager.swift       — Persistent Curve25519 key pair (Keychain)
  TrustLevel.swift               — Verified / Linked / Unknown enum
  TrustedContact.swift           — Contact model with public key + trust
  TrustedContactStore.swift      — Encrypted persistence for contacts
  SessionKeyManager.swift        — ECDH + AES-256-GCM per-connection
  KeyExchangeMessage.swift       — Wire protocol for key handshake
  PairingPayload.swift           — QR code payload with public keys

PeerDrop/UI/Security/
  KeyChangeAlertView.swift       — Full-screen key change warning
  TrustBadgeView.swift           — Inline trust level badge
  VerificationView.swift         — Safety number confirmation screen
  SecurityDashboardView.swift    — Pet-integrated security overview

PeerDropTests/
  IdentityKeyManagerTests.swift  — 9 tests
  TrustedContactTests.swift      — 6 tests
  TrustedContactStoreTests.swift — 10 tests
  SessionKeyManagerTests.swift   — 6 tests
  KeyExchangeMessageTests.swift  — 4 tests
  PairingPayloadTests.swift      — 4 tests
  PeerIdentitySecurityTests.swift — 3 tests
```

## Files Modified

```
PeerDrop/Core/ConnectionManager.swift  — Add trustedContactStore, key exchange flow
PeerDrop/Core/PeerIdentity.swift       — Add identityPublicKey, identityFingerprint
PeerDrop/UI/Connection/ConnectionQRView.swift — Use PairingPayload for QR codes
```
