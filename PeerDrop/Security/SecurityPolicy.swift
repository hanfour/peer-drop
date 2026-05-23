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
