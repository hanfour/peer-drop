import Foundation

/// The signed wire envelope for a `SecurityPolicy`, as served by the
/// Cloudflare worker's `/v2/config/crypto-policy` endpoint and persisted
/// to the local cache at `~/Documents/Security/crypto-policy.json`.
///
/// Per spec §5.1 + §5.3:
///   - `signature` is base64 Ed25519 over the canonical JSON of
///     `{schemaVersion, issuedAt, expiresAt, policy}` (RFC 8785-subset
///     produced by `CanonicalJSON.serialize(_:)`).
///   - Signing key lives offline; the worker only serves a pre-signed
///     blob from an environment variable.
public struct SignedCryptoPolicy: Codable, Equatable {
    /// Wire-format generation. Currently 1. Future incompatible changes bump
    /// this; clients that don't understand the new version fall back to bundled
    /// defaults and record `policy.version_unsupported`.
    public let schemaVersion: Int

    /// Unix epoch seconds at which the issuer signed this blob.
    public let issuedAt: UInt64

    /// Unix epoch seconds after which the client treats this blob as advisory
    /// (still usable from cache if fetch fails, but the client flags it
    /// `policy.expired_in_use` and prefers a fresh fetch).
    public let expiresAt: UInt64

    /// The actual policy. Encoded as a nested JSON object per spec §5.1.
    public let policy: SecurityPolicy

    /// base64 Ed25519 signature over the canonical JSON of the other 4
    /// fields. Verified at parse time by `SecurityPolicyStore.parseSignedPolicy`.
    public let signature: String

    public init(
        schemaVersion: Int,
        issuedAt: UInt64,
        expiresAt: UInt64,
        policy: SecurityPolicy,
        signature: String
    ) {
        self.schemaVersion = schemaVersion
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.policy = policy
        self.signature = signature
    }
}
