import XCTest
@testable import PeerDrop

/// Tests for the decrypt-failure banner (Task A.4).
///
/// When a peer rotates their identity key without our knowledge, every
/// subsequent message from them will decrypt-fail. Without surfacing this,
/// the user just sees nothing arrive. These tests assert:
///
///  1. A single failure does not surface a banner — guards against transient
///     ratchet hiccups.
///  2. After `decryptFailureBannerThreshold` consecutive failures, the
///     banner is published.
///  3. A successful decrypt resets the counter and clears any visible banner.
///  4. User dismissal also resets the counter so the banner doesn't immediately
///     re-appear on the next failure.
///  5. Failure counters are independent per-peer.
@MainActor
final class DecryptFailureBannerTests: XCTestCase {

    func test_oneFailure_doesNotShowBanner() {
        let cm = ConnectionManager()
        cm.recordDecryptFailureForTesting(contactId: "peer-1", displayName: "Alice")
        XCTAssertNil(cm.decryptFailureBanner)
    }

    func test_twoFailures_doNotShowBanner() {
        let cm = ConnectionManager()
        cm.recordDecryptFailureForTesting(contactId: "peer-1", displayName: "Alice")
        cm.recordDecryptFailureForTesting(contactId: "peer-1", displayName: "Alice")
        XCTAssertNil(cm.decryptFailureBanner, "Below threshold must not surface banner")
    }

    func test_threeFailures_showBanner() {
        let cm = ConnectionManager()
        for _ in 0..<3 {
            cm.recordDecryptFailureForTesting(contactId: "peer-1", displayName: "Alice")
        }
        XCTAssertEqual(cm.decryptFailureBanner?.contactId, "peer-1")
        XCTAssertEqual(cm.decryptFailureBanner?.displayName, "Alice")
    }

    func test_successfulDecrypt_resetsCounter() {
        let cm = ConnectionManager()
        for _ in 0..<2 {
            cm.recordDecryptFailureForTesting(contactId: "peer-1", displayName: "Alice")
        }
        cm.recordDecryptSuccessForTesting(contactId: "peer-1")

        // Now try 2 more failures — must NOT trigger banner because counter reset.
        for _ in 0..<2 {
            cm.recordDecryptFailureForTesting(contactId: "peer-1", displayName: "Alice")
        }
        XCTAssertNil(cm.decryptFailureBanner)
    }

    func test_dismissBanner_resetsCounter() {
        let cm = ConnectionManager()
        for _ in 0..<3 {
            cm.recordDecryptFailureForTesting(contactId: "peer-1", displayName: "Alice")
        }
        XCTAssertNotNil(cm.decryptFailureBanner)

        cm.dismissDecryptFailureBanner()
        XCTAssertNil(cm.decryptFailureBanner)

        // Next failure should NOT immediately re-trigger the banner.
        cm.recordDecryptFailureForTesting(contactId: "peer-1", displayName: "Alice")
        XCTAssertNil(cm.decryptFailureBanner)
    }

    func test_failuresFromDifferentPeers_independent() {
        let cm = ConnectionManager()
        for _ in 0..<3 {
            cm.recordDecryptFailureForTesting(contactId: "peer-A", displayName: "Alice")
        }
        // Banner for A.
        XCTAssertEqual(cm.decryptFailureBanner?.contactId, "peer-A")

        // Failures from peer B don't override peer A's banner (and B's counter
        // is independent — only one failure so far, well under threshold).
        cm.recordDecryptFailureForTesting(contactId: "peer-B", displayName: "Bob")
        XCTAssertEqual(cm.decryptFailureBanner?.contactId, "peer-A")
    }

    func test_successfulDecryptFromBanneredPeer_dismissesBanner() {
        let cm = ConnectionManager()
        for _ in 0..<3 {
            cm.recordDecryptFailureForTesting(contactId: "peer-1", displayName: "Alice")
        }
        XCTAssertNotNil(cm.decryptFailureBanner)

        cm.recordDecryptSuccessForTesting(contactId: "peer-1")
        XCTAssertNil(cm.decryptFailureBanner, "Successful decrypt must clear banner for that peer")
    }

    func test_successfulDecryptFromOtherPeer_doesNotClearBanner() {
        let cm = ConnectionManager()
        for _ in 0..<3 {
            cm.recordDecryptFailureForTesting(contactId: "peer-A", displayName: "Alice")
        }
        XCTAssertEqual(cm.decryptFailureBanner?.contactId, "peer-A")

        // A successful decrypt from a different peer must not affect
        // peer-A's banner.
        cm.recordDecryptSuccessForTesting(contactId: "peer-B")
        XCTAssertEqual(cm.decryptFailureBanner?.contactId, "peer-A")
    }
}
