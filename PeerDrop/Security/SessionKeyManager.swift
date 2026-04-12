import Foundation
import CryptoKit

enum SessionKeyManager {

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

    static func encrypt(_ plaintext: Data, with key: SymmetricKey) throws -> Data {
        let sealedBox = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealedBox.combined else {
            throw CryptoError.encryptionFailed
        }
        return combined
    }

    static func decrypt(_ ciphertext: Data, with key: SymmetricKey) throws -> Data {
        let sealedBox = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(sealedBox, using: key)
    }

    enum CryptoError: Error {
        case encryptionFailed
    }
}
