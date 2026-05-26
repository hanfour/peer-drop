import Foundation
import CryptoKit

// MARK: - Signed Pre-Key

/// A medium-term key signed by the identity signing key.
/// Rotated every 7 days. Allows peers to initiate X3DH without us being online.
public struct SignedPreKey {
    public let id: UInt32
    public let publicKey: Data                  // Curve25519 agreement public key
    public let privateKey: Data                 // Curve25519 agreement private key (stored locally only)
    public let signature: Data                  // Ed25519 signature of publicKey
    public let timestamp: Date

    public init(id: UInt32, publicKey: Data, privateKey: Data, signature: Data, timestamp: Date) {
        self.id = id
        self.publicKey = publicKey
        self.privateKey = privateKey
        self.signature = signature
        self.timestamp = timestamp
    }

    public static func generate(id: UInt32, signingKey: IdentityKeyManager) throws -> SignedPreKey {
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

    public func verify(with signingPublicKey: Curve25519.Signing.PublicKey) -> Bool {
        signingPublicKey.isValidSignature(signature, for: publicKey)
    }

    /// Public-only version for wire transmission (no private key)
    public func asPublic() -> PublicSignedPreKey {
        PublicSignedPreKey(id: id, publicKey: publicKey, signature: signature, timestamp: timestamp)
    }

    /// Reconstruct private key for crypto operations
    public func agreementPrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
    }
}

/// Wire-safe version of SignedPreKey (no private key)
public struct PublicSignedPreKey: Codable {
    public let id: UInt32
    public let publicKey: Data
    public let signature: Data
    /// **NOT verified — informational only.** This `Date` was added before C1
    /// existed and is purely a hint from the sender's wall clock. For
    /// security-relevant timestamp checks (freshness against
    /// `policy.spkMaxAgeDays`), read `PreKeyBundle.signedPreKeyTimestamp` —
    /// it carries a separate signed Ed25519 attestation per spec §4.1.
    public let timestamp: Date

    public init(id: UInt32, publicKey: Data, signature: Data, timestamp: Date) {
        self.id = id
        self.publicKey = publicKey
        self.signature = signature
        self.timestamp = timestamp
    }

    public func verify(with signingPublicKey: Curve25519.Signing.PublicKey) -> Bool {
        signingPublicKey.isValidSignature(signature, for: publicKey)
    }

    public func agreementPublicKey() throws -> Curve25519.KeyAgreement.PublicKey {
        try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
    }
}

// MARK: - One-Time Pre-Key

/// A single-use key consumed during X3DH. Provides per-session uniqueness.
public struct OneTimePreKey {
    public let id: UInt32
    public let publicKey: Data
    public let privateKey: Data

    public init(id: UInt32, publicKey: Data, privateKey: Data) {
        self.id = id
        self.publicKey = publicKey
        self.privateKey = privateKey
    }

    public static func generate(id: UInt32) -> OneTimePreKey {
        let keyPair = Curve25519.KeyAgreement.PrivateKey()
        return OneTimePreKey(
            id: id,
            publicKey: keyPair.publicKey.rawRepresentation,
            privateKey: keyPair.rawRepresentation
        )
    }

    public static func generateBatch(startId: UInt32, count: Int) -> [OneTimePreKey] {
        (0..<count).map { OneTimePreKey.generate(id: startId + UInt32($0)) }
    }

    public func asPublic() -> PublicOneTimePreKey {
        PublicOneTimePreKey(id: id, publicKey: publicKey)
    }

    public func agreementPrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
    }
}

/// Wire-safe version (no private key)
public struct PublicOneTimePreKey: Codable {
    public let id: UInt32
    public let publicKey: Data

    public init(id: UInt32, publicKey: Data) {
        self.id = id
        self.publicKey = publicKey
    }

    public func agreementPublicKey() throws -> Curve25519.KeyAgreement.PublicKey {
        try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
    }
}

// MARK: - Pre-Key Bundle (wire format)

/// The complete public key package uploaded to the pre-key server.
/// Peers fetch this to initiate X3DH key agreement.
public struct PreKeyBundle: Codable {
    public let identityKey: Data                    // Curve25519 identity public key
    public let signingKey: Data                     // Ed25519 signing public key
    public let signedPreKey: PublicSignedPreKey      // Medium-term key + signature
    public let oneTimePreKeys: [PublicOneTimePreKey] // Single-use keys

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
    public let signedPreKeyTimestamp: UInt64?
    public let signedPreKeyTimestampSignature: Data?

    /// Memberwise init with defaults for the new v5.4 fields so that all
    /// existing call sites (v5.0–v5.3 style, no timestamp args) compile
    /// unchanged. Task 6.2 will supply real values when signing the SPK.
    public init(
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
