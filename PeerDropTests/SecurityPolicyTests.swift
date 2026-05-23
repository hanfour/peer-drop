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
        XCTAssertEqual(p.opkRetryMaxAttempts, 5)
        XCTAssertEqual(p.opkRetryIntervalSeconds, 60)
        XCTAssertEqual(p.skippedKeyTTLDays, 30)
        XCTAssertEqual(p.skippedKeyMaxCount, 200)
        XCTAssertEqual(p.consumedOPKPruneWindowDays, 90)
    }
}
