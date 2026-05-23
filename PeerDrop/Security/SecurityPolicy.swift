import Foundation

/// Immutable value type holding all tunable crypto-hardening thresholds.
/// Read at every relevant call site; never mutated in-place. Merging is
/// always stronger-of-two — see `merged(local:remote:)`.
public struct SecurityPolicy: Equatable, Codable {

    public enum OPKExhaustionBehavior: String, Codable, Comparable {
        /// Current pre-v5.4 behavior: skip DH4 and proceed with weakened
        /// forward secrecy.
        case proceedWithoutDH4

        /// v5.4+ behavior: refuse to initiate X3DH, schedule retry.
        case failClosed

        private var rank: Int {
            switch self {
            case .proceedWithoutDH4: return 0
            case .failClosed:        return 1
            }
        }

        /// Strictness ordering: failClosed > proceedWithoutDH4.
        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rank < rhs.rank
        }
    }

    public enum SPKExpirationBehavior: String, Codable, Comparable {
        /// Warn on expiration but allow proceed.
        case warn

        /// Reject if SPK is expired.
        case reject

        private var rank: Int {
            switch self {
            case .warn:   return 0
            case .reject: return 1
            }
        }

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rank < rhs.rank
        }
    }

    public let spkMaxAgeDays: Int
    public let spkExpirationBehavior: SPKExpirationBehavior
    private let opkExhaustionLegacy: OPKExhaustionBehavior
    private let opkExhaustionStrict: OPKExhaustionBehavior
    public let opkRetryMaxAttempts: Int
    public let opkRetryIntervalSeconds: Int
    public let skippedKeyTTLDays: Int
    public let skippedKeyMaxCount: Int
    public let consumedOPKPruneWindowDays: Int

    public func opkExhaustionBehavior(_ version: PeerVersion) -> OPKExhaustionBehavior {
        switch version {
        case .legacy:
            return opkExhaustionLegacy
        case .v5_4_plus, .unknown:
            // .unknown: fail-closed by design — no version information = treat as strict.
            return opkExhaustionStrict
        }
    }

    public init(
        spkMaxAgeDays: Int,
        spkExpirationBehavior: SPKExpirationBehavior,
        opkExhaustionLegacy: OPKExhaustionBehavior,
        opkExhaustionStrict: OPKExhaustionBehavior,
        opkRetryMaxAttempts: Int,
        opkRetryIntervalSeconds: Int,
        skippedKeyTTLDays: Int,
        skippedKeyMaxCount: Int,
        consumedOPKPruneWindowDays: Int
    ) {
        self.spkMaxAgeDays = spkMaxAgeDays
        self.spkExpirationBehavior = spkExpirationBehavior
        self.opkExhaustionLegacy = opkExhaustionLegacy
        self.opkExhaustionStrict = opkExhaustionStrict
        self.opkRetryMaxAttempts = opkRetryMaxAttempts
        self.opkRetryIntervalSeconds = opkRetryIntervalSeconds
        self.skippedKeyTTLDays = skippedKeyTTLDays
        self.skippedKeyMaxCount = skippedKeyMaxCount
        self.consumedOPKPruneWindowDays = consumedOPKPruneWindowDays
    }

    public static let bundledDefault = SecurityPolicy(
        spkMaxAgeDays: 21,
        spkExpirationBehavior: .warn,
        opkExhaustionLegacy: .proceedWithoutDH4,
        opkExhaustionStrict: .failClosed,
        opkRetryMaxAttempts: 5,
        opkRetryIntervalSeconds: 60,
        skippedKeyTTLDays: 30,
        skippedKeyMaxCount: 200,
        consumedOPKPruneWindowDays: 90
    )
}

extension SecurityPolicy {
    /// Stronger-of-two merge: for each field, pick the value that is at
    /// least as strict as both inputs. This is the core invariant that
    /// prevents a compromised remote policy from weakening local
    /// crypto: `merged(local, remote)` is never weaker than `local`.
    ///
    /// Field-by-field strictness:
    /// - shorter maxAge / TTL / count → stricter (use `min`)
    /// - longer pruneWindow → stricter (use `max`)
    /// - higher retry max → better UX, equal security (use `max`)
    /// - `.reject > .warn`, `.failClosed > .proceedWithoutDH4` (use `max`)
    /// - opkRetryIntervalSeconds is pure UX — local wins
    public static func merged(local: SecurityPolicy, remote: SecurityPolicy) -> SecurityPolicy {
        return SecurityPolicy(
            spkMaxAgeDays: min(local.spkMaxAgeDays, remote.spkMaxAgeDays),
            spkExpirationBehavior: max(local.spkExpirationBehavior, remote.spkExpirationBehavior),
            opkExhaustionLegacy: max(local.opkExhaustionBehavior(.legacy), remote.opkExhaustionBehavior(.legacy)),
            opkExhaustionStrict: max(local.opkExhaustionBehavior(.v5_4_plus), remote.opkExhaustionBehavior(.v5_4_plus)),
            opkRetryMaxAttempts: max(local.opkRetryMaxAttempts, remote.opkRetryMaxAttempts),
            opkRetryIntervalSeconds: local.opkRetryIntervalSeconds,
            skippedKeyTTLDays: min(local.skippedKeyTTLDays, remote.skippedKeyTTLDays),
            skippedKeyMaxCount: min(local.skippedKeyMaxCount, remote.skippedKeyMaxCount),
            consumedOPKPruneWindowDays: max(local.consumedOPKPruneWindowDays, remote.consumedOPKPruneWindowDays)
        )
    }
}

extension SecurityPolicy {

    /// Errors thrown by `validateInvariants()`. Each case represents a
    /// constraint that a `SecurityPolicy` must satisfy to be considered
    /// internally consistent regardless of where it came from (bundled,
    /// cache, or remote fetch).
    public enum InvariantError: Error, Equatable {
        /// `consumedOPKPruneWindowDays` must be at least `spkMaxAgeDays * 4`.
        ///
        /// Reasoning: C1 (SPK timestamp binding) rejects any prekey bundle
        /// older than `spkMaxAgeDays`. C4 (consumed-OPK prune) drops the
        /// "this OPK was consumed" memory after `consumedOPKPruneWindowDays`.
        /// If the prune window is shorter than ~4× the SPK max age, an
        /// attacker could replay a bundle whose OPK has been pruned from
        /// the consumed set. The 4× safety margin guarantees the bundle's
        /// SPK is rejected by C1 before the OPK becomes replayable via C4.
        case pruneWindowTooShort(prune: Int, required: Int)
    }

    /// Validate the cross-field invariants that must hold for any
    /// `SecurityPolicy` instance used at runtime. Called by
    /// `SecurityPolicyStore` after fetch + clamp + merge, before
    /// publishing the new policy as `current`. A policy that fails
    /// validation falls back to bundled defaults.
    public func validateInvariants() throws {
        let required = spkMaxAgeDays * 4
        if consumedOPKPruneWindowDays < required {
            throw InvariantError.pruneWindowTooShort(
                prune: consumedOPKPruneWindowDays,
                required: required
            )
        }
    }
}
