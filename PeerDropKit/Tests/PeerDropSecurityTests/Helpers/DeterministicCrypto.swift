import Foundation
import CryptoKit

/// Deterministic key factories for test vectors. Never use these for any
/// production code — seeds are predictable, output is reproducible.
public enum DeterministicCrypto {

    /// Build a Curve25519 KeyAgreement key from a 32-byte seed. If the seed
    /// happens to be an invalid Curve25519 scalar (e.g., a small-subgroup
    /// element — astronomically unlikely with arbitrary input but possible),
    /// retry with SHA-256 of the seed up to 8 times before failing.
    public static func curve25519AgreementKey(seed: Data) -> Curve25519.KeyAgreement.PrivateKey {
        var attempt = seed
        for _ in 0..<8 {
            if let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: attempt) {
                return key
            }
            attempt = Data(SHA256.hash(data: attempt))
        }
        preconditionFailure("Could not derive Curve25519 agreement key from seed after 8 retries")
    }

    /// Same idea as `curve25519AgreementKey` but for the signing variant.
    public static func curve25519SigningKey(seed: Data) -> Curve25519.Signing.PrivateKey {
        var attempt = seed
        for _ in 0..<8 {
            if let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: attempt) {
                return key
            }
            attempt = Data(SHA256.hash(data: attempt))
        }
        preconditionFailure("Could not derive Curve25519 signing key from seed after 8 retries")
    }
}
