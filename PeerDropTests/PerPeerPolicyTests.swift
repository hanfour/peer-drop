import XCTest
@testable import PeerDrop

final class PerPeerPolicyTests: XCTestCase {
    func test_legacy_peer_skips_C1_C2_strict_behaviors() {
        let base = SecurityPolicy.bundledDefault
        let p = PeerPolicy.policy(for: .legacy, base: base)
        // legacy peer's OPK exhaustion stays proceedWithoutDH4
        XCTAssertEqual(p.opkExhaustionBehavior(.legacy), .proceedWithoutDH4)
    }

    func test_v5_4_peer_uses_strict_behaviors() {
        let base = SecurityPolicy.bundledDefault
        let p = PeerPolicy.policy(for: .v5_4_plus, base: base)
        XCTAssertEqual(p.opkExhaustionBehavior(.v5_4_plus), .failClosed)
    }

    func test_unknown_peer_defaults_to_strict() {
        let base = SecurityPolicy.bundledDefault
        let p = PeerPolicy.policy(for: .unknown, base: base)
        XCTAssertEqual(p.opkExhaustionBehavior(.unknown), .failClosed)
    }
}
