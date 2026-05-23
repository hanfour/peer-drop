import Foundation
import Combine
import CryptoKit

/// Boot-time policy loader. In PR1 (this task), `current` is initialized
/// synchronously from a cached signed-policy file or the bundled
/// default. PR4 will add the async fetch + Ed25519 signature verification
/// that updates `current` from the worker endpoint.
///
/// `@MainActor` so SwiftUI consumers can subscribe to `$current` directly
/// without dispatch dancing.
@MainActor
public final class SecurityPolicyStore: ObservableObject {

    @Published public private(set) var current: SecurityPolicy

    private let storageDirectory: URL
    private let publicKeys: [Data]   // Ed25519 public keys — used by PR4's signature verification
    private let metrics: CryptoHardeningMetrics?

    public init(
        storageDirectory: URL,
        publicKeys: [Data],
        metrics: CryptoHardeningMetrics? = nil
    ) {
        self.storageDirectory = storageDirectory
        self.publicKeys = publicKeys
        self.metrics = metrics
        // Synchronous boot load. PR4 will read + signature-verify the
        // cached blob here; for PR1, always return the bundled default
        // so the consumer surface is testable end-to-end.
        self.current = Self.loadFromCacheOrBundled(
            directory: storageDirectory,
            publicKeys: publicKeys,
            metrics: metrics
        )
    }

    private static func loadFromCacheOrBundled(
        directory: URL,
        publicKeys: [Data],
        metrics: CryptoHardeningMetrics?
    ) -> SecurityPolicy {
        // PR4: read `directory/crypto-policy.json`, verify signature
        // against `publicKeys`, parse, clamp, merge with bundled default.
        // For PR1, no consumers exist yet, so we always return the
        // bundled default and record a cache-hit telemetry event so
        // the metrics wiring is exercised end-to-end.
        metrics?.record(.policyCacheHit)
        return .bundledDefault
    }
}

// MARK: - parseSignedPolicy

extension SecurityPolicyStore {

    public enum ParseError: Error, Equatable {
        case malformedJSON
        case invalidSignature
        case unsupportedSchemaVersion(Int)
        case invariantViolation
    }

    /// Verify and parse a signed-policy blob. Returns the decoded
    /// `SignedCryptoPolicy` on success; throws `ParseError` on the first
    /// failure encountered (in order: JSON parse → schema version → signature → invariants).
    ///
    /// `publicKeys` is the list of trusted Ed25519 verification keys
    /// (typically from `Info.plist` `CryptoPolicyPublicKeys`). The signature
    /// is accepted if ANY key in the list verifies it — enables in-flight
    /// key rotation by shipping a build that trusts both the old and new
    /// public keys for a transition window.
    ///
    /// Empty `publicKeys` (no trust roots configured) → `invalidSignature`.
    /// This matches the PR1 placeholder-handling intent: until PR4 ships real
    /// keys to the bundle, the parse path refuses remote policies entirely
    /// rather than silently falling back to "no signature check".
    public nonisolated static func parseSignedPolicy(
        _ data: Data,
        publicKeys: [Data]
    ) throws -> SignedCryptoPolicy {
        // 1. Parse JSON envelope.
        let decoded: SignedCryptoPolicy
        do {
            decoded = try JSONDecoder().decode(SignedCryptoPolicy.self, from: data)
        } catch {
            throw ParseError.malformedJSON
        }

        // 2. Schema version gate.
        guard decoded.schemaVersion == 1 else {
            throw ParseError.unsupportedSchemaVersion(decoded.schemaVersion)
        }

        // 3. Signature verification.
        // Reconstruct the signed payload (everything except the signature) as
        // canonical JSON, then try each public key in turn.
        let policyAsJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded.policy))
        let payloadDict: [String: Any] = [
            "schemaVersion": decoded.schemaVersion,
            "issuedAt": decoded.issuedAt,
            "expiresAt": decoded.expiresAt,
            "policy": policyAsJSON
        ]
        let canonical: Data
        do {
            canonical = try CanonicalJSON.serialize(payloadDict)
        } catch {
            // Should not happen: SignedCryptoPolicy is well-typed Codable.
            throw ParseError.malformedJSON
        }

        guard let sigBytes = Data(base64Encoded: decoded.signature) else {
            throw ParseError.invalidSignature
        }

        var matched = false
        for pkBytes in publicKeys {
            if let pk = try? Curve25519.Signing.PublicKey(rawRepresentation: pkBytes),
               pk.isValidSignature(sigBytes, for: canonical) {
                matched = true
                break
            }
        }
        guard matched else {
            throw ParseError.invalidSignature
        }

        // 4. Cross-field invariants (pruneWindow ≥ spkMaxAge × 4, etc.)
        do {
            try decoded.policy.validateInvariants()
        } catch {
            throw ParseError.invariantViolation
        }

        return decoded
    }
}
