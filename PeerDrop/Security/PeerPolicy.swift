import Foundation

/// Resolves the effective `SecurityPolicy` for a given peer based on its
/// detected protocol version. The base policy is the merged
/// local-stronger-of-two-remote; this function applies per-peer
/// adjustments without weakening it.
public enum PeerPolicy {
    /// Currently a no-op pass-through: per-peer logic is consumed
    /// inside the call sites via `base.opkExhaustionBehavior(version)`.
    /// This wrapper exists so future per-peer adjustments (e.g.,
    /// version-specific timeouts, special-case overrides) have a single
    /// entry point.
    public static func policy(for version: PeerVersion, base: SecurityPolicy) -> SecurityPolicy {
        return base
    }
}
