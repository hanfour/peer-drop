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

    // NEW for v5.4 (Task 6.1 — C1 SPK timestamp binding).
    // Both fields are optional so bundles emitted by v5.0–v5.3 clients decode
    // unchanged on new receivers (synthesized Codable returns nil for absent
    // JSON keys). v5.0–v5.3 receivers also ignore these unknown JSON keys when
    // decoding bundles emitted by v5.4+ clients.
    //
    // signedPreKeyTimestamp            — Unix seconds when the SPK was created/signed.
    // signedPreKeyTimestampSignature   — Ed25519 signature over
    //                                    SPK_pubkey || timestamp_BE_8_bytes
    //                                    using the identity signing key.
    //                                    Verified by Task 6.3's freshness gate.
    let signedPreKeyTimestamp: UInt64?
    let signedPreKeyTimestampSignature: Data?

    /// Memberwise init with defaults for the new v5.4 fields so that all
    /// existing call sites (v5.0–v5.3 style, no timestamp args) compile
    /// unchanged. Task 6.2 will supply real values when signing the SPK.
    init(
        identityKey: Data,
        signingKey: Data,
        signedPreKey: PublicSignedPreKey,
        oneTimePreKeys: [PublicOneTimePreKey],
        signedPreKeyTimestamp: UInt64? = nil,
        signedPreKeyTimestampSignature: Data? = nil
    ) {
        self.identityKey = identityKey
        self.signingKey = signingKey
        self.signedPreKey = signedPreKey
        self.oneTimePreKeys = oneTimePreKeys
        self.signedPreKeyTimestamp = signedPreKeyTimestamp
        self.signedPreKeyTimestampSignature = signedPreKeyTimestampSignature
    }
}
