import Foundation
import Security
import CryptoKit

/// Manages ephemeral self-signed TLS certificates for peer connections.
/// Uses a P-256 key pair; the "certificate" is derived from the public key
/// and used solely for fingerprint-based trust-on-first-use verification.
final class CertificateManager {
    private(set) var identity: SecIdentity?
    private(set) var certificate: SecCertificate?
    private(set) var fingerprint: String?
    private var privateKey: SecKey?

    init() {
        generateEphemeralKeyPair()
    }

    /// Generate an ephemeral P-256 key pair and derive a fingerprint.
    private func generateEphemeralKeyPair() {
        let keyTag = "com.peerdrop.ephemeral.\(UUID().uuidString)"

        let keyAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrIsPermanent as String: false,
            kSecPrivateKeyAttrs as String: [
                kSecAttrApplicationTag as String: keyTag.data(using: .utf8)!
            ]
        ]

        var error: Unmanaged<CFError>?
        guard let privKey = SecKeyCreateRandomKey(keyAttributes as CFDictionary, &error) else {
            print("[CertificateManager] Failed to create private key: \(error!.takeRetainedValue())")
            return
        }
        self.privateKey = privKey

        guard let publicKey = SecKeyCopyPublicKey(privKey) else {
            print("[CertificateManager] Failed to get public key")
            return
        }

        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            print("[CertificateManager] Failed to export public key")
            return
        }

        // Compute fingerprint from public key data
        let hash = SHA256.hash(data: publicKeyData)
        fingerprint = hash.map { String(format: "%02x", $0) }.joined()

        // Attempt to create a certificate from the key and store identity in keychain
        storeIdentity(privateKey: privKey, keyTag: keyTag)
    }

    private func storeIdentity(privateKey: SecKey, keyTag: String) {
        // Store the key in keychain so we can retrieve a SecIdentity
        let addKeyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecValueRef as String: privateKey,
            kSecAttrApplicationTag as String: keyTag.data(using: .utf8)!,
        ]
        SecItemAdd(addKeyQuery as CFDictionary, nil)

        // Try to retrieve identity (requires a matching certificate in keychain)
        var identityRef: CFTypeRef?
        let identityQuery: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrApplicationTag as String: keyTag.data(using: .utf8)!,
            kSecReturnRef as String: true
        ]
        if SecItemCopyMatching(identityQuery as CFDictionary, &identityRef) == errSecSuccess {
            self.identity = (identityRef as! SecIdentity)
        }

        // Clean up keychain entry
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag.data(using: .utf8)!,
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
