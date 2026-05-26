import XCTest
@testable import PeerDropSecurity

final class SecurityPolicyProperties: XCTestCase {

    func test_property_merge_neverWeakerThanInputs() {
        PropertyTest.forAll(trials: 200, seed: 1) { rng in
            let a = randomBoundedPolicy(rng: &rng)
            let b = randomBoundedPolicy(rng: &rng)
            let m = SecurityPolicy.merged(local: a, remote: b)
            return policyStrictness(m) >= max(policyStrictness(a), policyStrictness(b))
        }
    }

    func test_property_clamp_alwaysInBounds() {
        PropertyTest.forAll(trials: 200, seed: 2) { rng in
            let raw = randomUnboundedPolicy(rng: &rng)
            let clamped = SecurityPolicyBounds.clamp(raw)
            return SecurityPolicyBounds.spkMaxAgeDaysRange.contains(clamped.spkMaxAgeDays)
                && SecurityPolicyBounds.opkRetryMaxAttemptsRange.contains(clamped.opkRetryMaxAttempts)
                && SecurityPolicyBounds.opkRetryIntervalSecondsRange.contains(clamped.opkRetryIntervalSeconds)
                && SecurityPolicyBounds.skippedKeyTTLDaysRange.contains(clamped.skippedKeyTTLDays)
                && SecurityPolicyBounds.skippedKeyMaxCountRange.contains(clamped.skippedKeyMaxCount)
                && SecurityPolicyBounds.consumedOPKPruneWindowDaysRange.contains(clamped.consumedOPKPruneWindowDays)
        }
    }

    func test_property_merge_isIdempotent_on_self() {
        PropertyTest.forAll(trials: 100, seed: 3) { rng in
            let a = randomBoundedPolicy(rng: &rng)
            let m = SecurityPolicy.merged(local: a, remote: a)
            return m == a
        }
    }

    func test_property_invariant_pruneWindow_holds_on_bundledDefault() {
        // Spot-check (no randomness needed): the constraint we ship with
        // must satisfy `pruneWindow >= spkMaxAge * 4`.
        XCTAssertNoThrow(try SecurityPolicy.bundledDefault.validateInvariants())
    }

    // MARK: - Generators

    private func randomBoundedPolicy(rng: inout PropertyTest.SeededRNG) -> SecurityPolicy {
        // Within bounds — used to exercise merge invariants without
        // tripping the pruneWindow >= spkMaxAge * 4 cross-field rule.
        // Pick spkMaxAge first, then pin pruneWindow to satisfy the
        // 4× margin given the bounds.
        let spkMaxAge = Int(rng.next() % 84) + 7              // 7..90
        let minPrune = max(spkMaxAge * 4, 30)
        let pruneSpan = min(365, 365 - minPrune)
        let pruneOffset = pruneSpan > 0 ? Int(rng.next() % UInt64(pruneSpan)) : 0
        let prune = minPrune + pruneOffset

        return SecurityPolicy(
            spkMaxAgeDays: spkMaxAge,
            spkExpirationBehavior: rng.next() % 2 == 0 ? .warn : .reject,
            opkExhaustionLegacy: rng.next() % 2 == 0 ? .proceedWithoutDH4 : .failClosed,
            opkExhaustionStrict: rng.next() % 2 == 0 ? .proceedWithoutDH4 : .failClosed,
            opkRetryMaxAttempts: Int(rng.next() % 20) + 1,
            opkRetryIntervalSeconds: Int(rng.next() % 571) + 30,
            skippedKeyTTLDays: Int(rng.next() % 365) + 1,
            skippedKeyMaxCount: Int(rng.next() % 1951) + 50,
            consumedOPKPruneWindowDays: prune
        )
    }

    private func randomUnboundedPolicy(rng: inout PropertyTest.SeededRNG) -> SecurityPolicy {
        // Deliberately out-of-bounds values — exercises clamp().
        SecurityPolicy(
            spkMaxAgeDays: Int(Int64(bitPattern: rng.next()) % 1000) - 500,
            spkExpirationBehavior: .warn,
            opkExhaustionLegacy: .proceedWithoutDH4,
            opkExhaustionStrict: .failClosed,
            opkRetryMaxAttempts: Int(rng.next() % 1000),
            opkRetryIntervalSeconds: Int(rng.next() % 10000),
            skippedKeyTTLDays: Int(rng.next() % 1000),
            skippedKeyMaxCount: Int(rng.next() % 10000),
            consumedOPKPruneWindowDays: Int(rng.next() % 1000)
        )
    }

    /// Composite scalar where larger = stricter. Pure for property-test ordering only.
    /// MUST be consistent with the actual merge rules:
    /// - shorter spkMaxAge / TTL / count → stricter
    /// - longer pruneWindow → stricter
    /// - higher enum strictness → stricter
    /// - higher retry max → equal security (we treat it neutral here)
    private func policyStrictness(_ p: SecurityPolicy) -> Int {
        var score = 0
        score += (90 - p.spkMaxAgeDays)                      // shorter = stricter
        score += (p.spkExpirationBehavior == .reject ? 100 : 0)
        score += (p.opkExhaustionBehavior(.legacy) == .failClosed ? 100 : 0)
        score += (p.opkExhaustionBehavior(.v5_4_plus) == .failClosed ? 100 : 0)
        score += (365 - p.skippedKeyTTLDays)                 // shorter TTL = stricter
        score += (2000 - p.skippedKeyMaxCount)               // smaller cap = stricter
        score += (p.consumedOPKPruneWindowDays - 30)         // longer = stricter
        return score
    }
}
