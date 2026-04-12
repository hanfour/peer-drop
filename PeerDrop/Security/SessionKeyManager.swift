import Foundation
import CryptoKit

enum SessionKeyManager {

    /// Derive a symmetric session key from ECDH shared secret.
    /// Both peers calling this with each other's public keys get the same key.
    /// sharedInfo includes both public keys (sorted) for domain separation.
    static func deriveSessionKey(
        myPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        peerPublicKey: Curve25519.KeyAgreement.PublicKey
    ) throws -> SymmetricKey {
        let shared = try myPrivateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
        // Bind session key to both parties by including sorted public keys in sharedInfo
        let myPub = myPrivateKey.publicKey.rawRepresentation
        let peerPub = peerPublicKey.rawRepresentation
        let sorted = [myPub, peerPub].sorted { $0.lexicographicallyPrecedes($1) }
        var sharedInfo = Data()
        sharedInfo.append(sorted[0])
        sharedInfo.append(sorted[1])
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: "PeerDrop-Session-v3".data(using: .utf8)!,
            sharedInfo: sharedInfo,
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
