import XCTest
@testable import PeerDrop

final class PerPeerPolicyIntegrationTests: XCTestCase {

    /// Per spec §3.3: legacy peers get `.proceedWithoutDH4` for C2 OPK exhaustion.
    func test_legacy_peer_routes_to_proceedWithoutDH4() {
        let policy = SecurityPolicy.bundledDefault
        XCTAssertEqual(policy.opkExhaustionBehavior(.legacy), .proceedWithoutDH4)
    }

    /// Per spec §3.3: v5.4+ peers get `.failClosed` for C2 OPK exhaustion.
    func test_v5_4_peer_routes_to_failClosed() {
        let policy = SecurityPolicy.bundledDefault
        XCTAssertEqual(policy.opkExhaustionBehavior(.v5_4_plus), .failClosed)
    }

    /// Per spec §3.3: unknown peers default to `.failClosed` (safe-default).
    func test_unknown_peer_routes_to_failClosed() {
        let policy = SecurityPolicy.bundledDefault
        XCTAssertEqual(policy.opkExhaustionBehavior(.unknown), .failClosed)
    }

    /// PeerPolicy.policy(for:base:) is a pass-through — doesn't strictify.
    /// Per-peer routing happens inside the version-aware accessors.
    func test_peerPolicy_is_passThrough() {
        let base = SecurityPolicy.bundledDefault
        let resolved = PeerPolicy.policy(for: .legacy, base: base)
        XCTAssertEqual(resolved, base)
        XCTAssertEqual(PeerPolicy.policy(for: .v5_4_plus, base: base), base)
        XCTAssertEqual(PeerPolicy.policy(for: .unknown, base: base), base)
    }

    /// Receiver-side end-to-end: an inbound envelope's protocolVersion maps
    /// to a TrustedContact.peerProtocolVersion via PeerVersion.from(...).
    /// Subsequent send paths can use that stored version for the C2 OPK gate.
    func test_endToEnd_envelopeVersionFlowsThroughToOPKGate() {
        let policy = SecurityPolicy.bundledDefault

        // Simulate a legacy sender (no protocolVersion in envelope).
        let legacyVersion = PeerVersion.from(envelopeProtocolVersion: nil)
        XCTAssertEqual(legacyVersion, .legacy)
        XCTAssertEqual(policy.opkExhaustionBehavior(legacyVersion), .proceedWithoutDH4,
                       "legacy sender → proceed without DH4 (no fail-closed)")

        // Simulate a v5.4+ sender (protocolVersion: 1).
        let v54Version = PeerVersion.from(envelopeProtocolVersion: 1)
        XCTAssertEqual(v54Version, .v5_4_plus)
        XCTAssertEqual(policy.opkExhaustionBehavior(v54Version), .failClosed,
                       "v5.4+ sender → fail-closed on OPK exhaustion")

        // Simulate a future-version sender (protocolVersion: 99).
        let futureVersion = PeerVersion.from(envelopeProtocolVersion: 99)
        XCTAssertEqual(futureVersion, .unknown)
        XCTAssertEqual(policy.opkExhaustionBehavior(futureVersion), .failClosed,
                       "unknown future sender → safe-default strict (fail-closed)")
    }
}
