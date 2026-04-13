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

    static func generate(id: UInt32, signingKey: IdentityKeyManager) throws -> SignedPreKey {
        let keyPair = Curve25519.KeyAgreement.PrivateKey()
        let pubKeyData = keyPair.publicKey.rawRepresentation
        let signature = try signingKey.sign(pubKeyData)
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
