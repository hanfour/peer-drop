import Foundation

/// Resolves the effective `SecurityPolicy` for a given peer based on its
/// detected protocol version. **Currently a no-op pass-through.**
///
/// The per-peer differentiation specified in spec §3.3 (legacy peers
/// skip C1/C2 strict enforcement, v5.4+ peers get strict) is NOT
/// implemented inside this resolver. Instead, it's woven into the
/// version-aware accessors on the policy itself:
/// - `SecurityPolicy.opkExhaustionBehavior(_ version:)` returns
///   `.proceedWithoutDH4` for `.legacy` and `.failClosed` for `.v5_4_plus`
///   / `.unknown` (PR1 wired this).
/// - `X3DH.verifyBundleFreshness` returns `.legacy` when timestamp fields
///   are nil; only `.v5_4_plus` peers hit the expired / malformed branches
///   (PR6 wired this).
///
/// As a result, callers don't need to "strictify" the base policy here —
/// they just need to use the version-aware accessors. This resolver exists
/// as a single entry point for future per-peer adjustments (e.g.,
/// version-specific retry intervals, per-peer rate limiting) that don't
/// fit cleanly into the per-field accessors.
public enum PeerPolicy {
    /// Returns the effective `SecurityPolicy` for the given peer version.
    /// Today: pass-through. Future per-peer overrides land here.
    public static func policy(for version: PeerVersion, base: SecurityPolicy) -> SecurityPolicy {
        return base
    }
}
