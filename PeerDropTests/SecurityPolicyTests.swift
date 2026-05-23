import XCTest
@testable import PeerDrop

final class SecurityPolicyTests: XCTestCase {
    func test_OPKExhaustionBehavior_strictness_ordering() {
        XCTAssertGreaterThan(
            SecurityPolicy.OPKExhaustionBehavior.failClosed,
            SecurityPolicy.OPKExhaustionBehavior.proceedWithoutDH4,
            "failClosed is strictly stronger than proceedWithoutDH4"
        )
    }

    func test_SPKExpirationBehavior_strictness_ordering() {
        XCTAssertGreaterThan(
            SecurityPolicy.SPKExpirationBehavior.reject,
            SecurityPolicy.SPKExpirationBehavior.warn,
            "reject is strictly stronger than warn"
        )
    }

    func test_bundledDefault_matchesSpec() {
        let p = SecurityPolicy.bundledDefault
        XCTAssertEqual(p.spkMaxAgeDays, 21)
        XCTAssertEqual(p.spkExpirationBehavior, .warn)
        XCTAssertEqual(p.opkExhaustionBehavior(.legacy), .proceedWithoutDH4)
        XCTAssertEqual(p.opkExhaustionBehavior(.v5_4_plus), .failClosed)
        XCTAssertEqual(p.opkExhaustionBehavior(.unknown), .failClosed)
        XCTAssertEqual(p.opkRetryMaxAttempts, 5)
        XCTAssertEqual(p.opkRetryIntervalSeconds, 60)
        XCTAssertEqual(p.skippedKeyTTLDays, 30)
        XCTAssertEqual(p.skippedKeyMaxCount, 200)
        XCTAssertEqual(p.consumedOPKPruneWindowDays, 90)
    }

    func test_bounds_clamp_outOfRangeValues() {
        let raw = SecurityPolicy(
            spkMaxAgeDays: 0,        // below min (7)
            spkExpirationBehavior: .warn,
            opkExhaustionLegacy: .proceedWithoutDH4,
            opkExhaustionStrict: .failClosed,
            opkRetryMaxAttempts: 999, // above max (20)
            opkRetryIntervalSeconds: 5, // below min (30)
            skippedKeyTTLDays: 30,
            skippedKeyMaxCount: 200,
            consumedOPKPruneWindowDays: 90
        )
        let clamped = SecurityPolicyBounds.clamp(raw)
        XCTAssertEqual(clamped.spkMaxAgeDays, 7)
        XCTAssertEqual(clamped.opkRetryMaxAttempts, 20)
        XCTAssertEqual(clamped.opkRetryIntervalSeconds, 30)
        // Bonus: confirm in-range fields pass through unchanged.
        XCTAssertEqual(clamped.skippedKeyMaxCount, 200)
    }

    func test_bounds_violations_listsOutOfRangeFields() {
        let raw = SecurityPolicy(
            spkMaxAgeDays: 0,        // below min
            spkExpirationBehavior: .warn,
            opkExhaustionLegacy: .proceedWithoutDH4,
            opkExhaustionStrict: .failClosed,
            opkRetryMaxAttempts: 5,
            opkRetryIntervalSeconds: 60,
            skippedKeyTTLDays: 30,
            skippedKeyMaxCount: 200,
            consumedOPKPruneWindowDays: 90
        )
        let violations = SecurityPolicyBounds.violations(raw)
        XCTAssertEqual(violations, ["spkMaxAgeDays"])

        let allInRange = SecurityPolicy.bundledDefault
        XCTAssertEqual(SecurityPolicyBounds.violations(allInRange), [])
    }
}
