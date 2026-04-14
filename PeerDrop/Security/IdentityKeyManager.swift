import Foundation
import CryptoKit
import os.log

/// Manages a persistent Curve25519 device identity key pair.
/// Private keys are stored in the iOS Keychain and never leave the device.
///
/// Note: Uses software Keychain, not Secure Enclave, because SE only supports P-256.
/// Curve25519 is chosen for Signal Protocol compatibility in Phase 2.
/// Uses AfterFirstUnlockThisDeviceOnly to support background BLE connections.
final class IdentityKeyManager {

    static let shared = IdentityKeyManager()

    private static let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "IdentityKeyManager")
    private let keychainService = "com.peerdrop.identity"
    private let agreementKeyAccount = "curve25519-agreement"
    private let signingKeyAccount = "ed25519-signing"
    // NSLock is non-reentrant — do not call publicKey/fingerprint from within lock-holding code paths
    private let lock = NSLock()
    private var cachedAgreementKey: Curve25519.KeyAgreement.PrivateKey?
    private var cachedSigningKey: Curve25519.Signing.PrivateKey?

    private init() {}

    // MARK: - Key Agreement (Curve25519 for ECDH)

    var publicKey: Curve25519.KeyAgreement.PublicKey {
        agreementPrivateKey.publicKey
    }

    /// Human-readable fingerprint: "A1B2 C3D4 E5F6 G7H8 I9J0" (80 bits, truncated SHA-256)
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
        try signingPrivateKey.signature(for: data)
    }

    func verify(signature: Data, for data: Data, from publicKey: Curve25519.Signing.PublicKey) -> Bool {
        publicKey.isValidSignature(signature, for: data)
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

    /// Expose agreement private key for X3DH key agreement. Only used within Security layer.
    func agreementPrivateKeyForX3DH() -> Curve25519.KeyAgreement.PrivateKey {
        agreementPrivateKey
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
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            Self.logger.error("Keychain write failed for \(account): OSStatus \(status)")
        }
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
