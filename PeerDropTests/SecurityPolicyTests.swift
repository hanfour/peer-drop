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
}
