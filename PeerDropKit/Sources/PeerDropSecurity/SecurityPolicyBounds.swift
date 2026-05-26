import Foundation

/// Hard local ranges for each policy field. Any value outside the range
/// (whether from local cache or remote fetch) is clamped to the nearest
/// bound. The bundled defaults are always within these ranges.
public enum SecurityPolicyBounds {

    public static let spkMaxAgeDaysRange = 7...90
    public static let opkRetryMaxAttemptsRange = 1...20
    public static let opkRetryIntervalSecondsRange = 30...600
    public static let skippedKeyTTLDaysRange = 1...365
    public static let skippedKeyMaxCountRange = 50...2000
    public static let consumedOPKPruneWindowDaysRange = 30...365

    public static func clamp(_ p: SecurityPolicy) -> SecurityPolicy {
        return SecurityPolicy(
            spkMaxAgeDays: p.spkMaxAgeDays.clamped(to: spkMaxAgeDaysRange),
            spkExpirationBehavior: p.spkExpirationBehavior,
            // Read backing fields via the version router:
            //   .legacy → opkExhaustionLegacy,  .v5_4_plus → opkExhaustionStrict.
            // (Necessary because the underlying stored properties are private to SecurityPolicy.)
            opkExhaustionLegacy: p.opkExhaustionBehavior(.legacy),
            opkExhaustionStrict: p.opkExhaustionBehavior(.v5_4_plus),
            opkRetryMaxAttempts: p.opkRetryMaxAttempts.clamped(to: opkRetryMaxAttemptsRange),
            opkRetryIntervalSeconds: p.opkRetryIntervalSeconds.clamped(to: opkRetryIntervalSecondsRange),
            skippedKeyTTLDays: p.skippedKeyTTLDays.clamped(to: skippedKeyTTLDaysRange),
            skippedKeyMaxCount: p.skippedKeyMaxCount.clamped(to: skippedKeyMaxCountRange),
            consumedOPKPruneWindowDays: p.consumedOPKPruneWindowDays.clamped(to: consumedOPKPruneWindowDaysRange)
        )
    }

    /// Returns the names of fields that were out of range (for telemetry).
    public static func violations(_ p: SecurityPolicy) -> [String] {
        var out: [String] = []
        if !spkMaxAgeDaysRange.contains(p.spkMaxAgeDays) { out.append("spkMaxAgeDays") }
        if !opkRetryMaxAttemptsRange.contains(p.opkRetryMaxAttempts) { out.append("opkRetryMaxAttempts") }
        if !opkRetryIntervalSecondsRange.contains(p.opkRetryIntervalSeconds) { out.append("opkRetryIntervalSeconds") }
        if !skippedKeyTTLDaysRange.contains(p.skippedKeyTTLDays) { out.append("skippedKeyTTLDays") }
        if !skippedKeyMaxCountRange.contains(p.skippedKeyMaxCount) { out.append("skippedKeyMaxCount") }
        if !consumedOPKPruneWindowDaysRange.contains(p.consumedOPKPruneWindowDays) { out.append("consumedOPKPruneWindowDays") }
        return out
    }
}

private extension BinaryInteger {
    func clamped(to range: ClosedRange<Self>) -> Self {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
