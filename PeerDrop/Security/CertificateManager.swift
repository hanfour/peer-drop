import Foundation
import Security
import CryptoKit
import os

/// Manages ephemeral self-signed TLS certificates for peer connections.
/// Uses a P-256 key pair; the "certificate" is derived from the public key
/// and used solely for fingerprint-based trust-on-first-use verification.
final class CertificateManager {
    private let logger = Logger(subsystem: "com.peerdrop.app", category: "CertificateManager")
    private(set) var identity: SecIdentity?
    private(set) var certificate: SecCertificate?
    private(set) var fingerprint: String?
    private(set) var setupError: String?
    private var privateKey: SecKey?

    /// Whether the security layer initialized successfully (at minimum a fingerprint).
    var isReady: Bool { fingerprint != nil }

    init() {
        generateEphemeralKeyPair()
    }

    /// Generate an ephemeral P-256 key pair and derive a fingerprint.
    private func generateEphemeralKeyPair() {
        let keyTag = "com.peerdrop.ephemeral.\(UUID().uuidString)"

        guard let keyTagData = keyTag.data(using: .utf8) else {
            setupError = "Failed to encode key tag"
            return
        }

        let keyAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrIsPermanent as String: false,
            kSecPrivateKeyAttrs as String: [
                kSecAttrApplicationTag as String: keyTagData
            ]
        ]

        var error: Unmanaged<CFError>?
        guard let privKey = SecKeyCreateRandomKey(keyAttributes as CFDictionary, &error) else {
            let cfError = error?.takeRetainedValue()
            let msg = "Failed to create private key: \(cfError.map { "\($0)" } ?? "unknown error")"
            logger.error("\(msg)")
            setupError = msg
            return
        }
        self.privateKey = privKey

        guard let publicKey = SecKeyCopyPublicKey(privKey) else {
            let msg = "Failed to derive public key"
            logger.warning("\(msg)")
            setupError = msg
            return
        }

        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            let msg = "Failed to export public key"
            logger.error("\(msg)")
            setupError = msg
            return
        }

        // Compute fingerprint from public key data
        let hash = SHA256.hash(data: publicKeyData)
        fingerprint = hash.map { String(format: "%02x", $0) }.joined()

        // Attempt to create a certificate from the key and store identity in keychain
        storeIdentity(privateKey: privKey, keyTag: keyTag)
    }

    private func storeIdentity(privateKey: SecKey, keyTag: String) {
        guard let keyTagData = keyTag.data(using: .utf8) else { return }

        // Store the key in keychain so we can retrieve a SecIdentity
        let addKeyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecValueRef as String: privateKey,
            kSecAttrApplicationTag as String: keyTagData,
        ]
        SecItemAdd(addKeyQuery as CFDictionary, nil)

        // Try to retrieve identity (requires a matching certificate in keychain)
        var identityRef: CFTypeRef?
        let identityQuery: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrApplicationTag as String: keyTagData,
            kSecReturnRef as String: true
        ]
        if SecItemCopyMatching(identityQuery as CFDictionary, &identityRef) == errSecSuccess,
           let ref = identityRef {
            // Safe: SecItemCopyMatching with kSecClassIdentity always returns SecIdentity
            self.identity = unsafeBitCast(ref, to: SecIdentity.self)
        }

        // Clean up keychain entry
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTagData,
        ]
        SecItemDelete(deleteQuery as CFDictionary)
    }

    /// Compute SHA-256 fingerprint of a certificate's DER data.
    func computeFingerprint(of certificate: SecCertificate) -> String {
        let data = SecCertificateCopyData(certificate) as Data
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
