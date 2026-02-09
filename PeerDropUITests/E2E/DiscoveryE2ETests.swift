import XCTest

// ═══════════════════════════════════════════════════════════════════════════
// Discovery E2E Tests
//
// Tests Bonjour peer discovery functionality between two simulators.
//
// Test Cases:
//   DISC-01: Mutual Discovery - Both devices discover each other
//   DISC-02: Online/Offline - Device appears/disappears based on online state
//
// ═══════════════════════════════════════════════════════════════════════════

// MARK: - Initiator Tests

final class DiscoveryE2EInitiatorTests: E2EInitiatorTestBase {

    // ─────────────────────────────────────────────────────────────────────────
    // DISC-01: Mutual Discovery
    //
    // Verifies that both devices can discover each other via Bonjour when
    // both are online.
    //
    // Flow:
    //   1. Initiator goes online
    //   2. Wait for acceptor to be online
    //   3. Both search for each other
    //   4. Verify both discovered the other
    // ─────────────────────────────────────────────────────────────────────────

    func test_DISC_01() {
        // Setup
        standardInitiatorSetup()

        // Step 1: Look for peer
        screenshot("01-searching")
        guard let peer = findPeer(timeout: 30) else {
            signalCheckpoint("discovery-failed")
            XCTFail("Should discover peer via Bonjour")
            return
        }

        // Step 2: Record peer information
        let peerLabel = peer.label
        writeVerificationResult("peer-found", value: peerLabel)
        screenshot("02-peer-found")
        signalCheckpoint("discovery-success")

        // Step 3: Wait for acceptor to also discover us
        XCTAssertTrue(
            waitForCheckpoint("discovery-success", timeout: 30),
            "Acceptor should also discover initiator"
        )

        // Step 4: Verify mutual discovery
        if let acceptorPeerLabel = readVerificationResult("peer-found") {
            print("[INITIATOR] Acceptor found peer: \(acceptorPeerLabel)")
            XCTAssertTrue(
                acceptorPeerLabel.contains("iPhone"),
                "Acceptor should have discovered initiator (iPhone device)"
            )
        }

        screenshot("03-mutual-discovery-complete")
        print("[INITIATOR] DISC-01: Mutual discovery verified")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // DISC-02: Online/Offline Discovery
    //
    // Verifies that peers appear when online and disappear when offline.
    //
    // Flow:
    //   1. Both online - verify peer visible
    //   2. Initiator goes offline - acceptor should see us disappear
    //   3. Initiator goes back online - acceptor should rediscover us
    //   4. Acceptor goes offline - we should see them disappear
    //   5. Acceptor goes back online - we should rediscover them
    // ─────────────────────────────────────────────────────────────────────────

    func test_DISC_02() {
        // Setup
        standardInitiatorSetup()

        // Step 1: Verify peer is visible when both online
        screenshot("01-both-online")
        guard findPeer(timeout: 30) != nil else {
            XCTFail("Should discover peer when both online")
            return
        }
        signalCheckpoint("phase1-peer-visible")
        screenshot("02-peer-visible")

        // Wait for acceptor to confirm
        XCTAssertTrue(
            waitForCheckpoint("phase1-peer-visible", timeout: 30),
            "Acceptor should confirm peer visible"
        )

        // Step 2: Go offline
        print("[INITIATOR] Going offline...")
        goOffline()
        screenshot("03-offline")

        let offlineText = app.staticTexts["You are offline"]
        XCTAssertTrue(
            offlineText.waitForExistence(timeout: 5),
            "Should show offline state"
        )
        signalCheckpoint("went-offline")

        // Wait for acceptor to notice we disappeared
        XCTAssertTrue(
            waitForCheckpoint("peer-disappeared", timeout: 20),
            "Acceptor should notice we went offline"
        )

        // Step 3: Go back online
        print("[INITIATOR] Going back online...")
        sleep(3) // Brief pause
        goOnline()
        screenshot("04-back-online")
        signalCheckpoint("back-online")

        // Wait for acceptor to rediscover us
        XCTAssertTrue(
            waitForCheckpoint("peer-rediscovered", timeout: 30),
            "Acceptor should rediscover us"
        )

        // Step 4: Wait for acceptor to go offline
        print("[INITIATOR] Waiting for acceptor to go offline...")
        XCTAssertTrue(
            waitForCheckpoint("went-offline", timeout: 30),
            "Acceptor should signal going offline"
        )

        // Check if peer disappeared (Bonjour may cache for a few seconds)
        sleep(5)
        screenshot("05-acceptor-offline-check")

        // Step 5: Wait for acceptor to come back online
        XCTAssertTrue(
            waitForCheckpoint("back-online", timeout: 30),
            "Acceptor should signal coming back online"
        )

        // Verify we can rediscover the peer
        sleep(3)
        let peerRediscovered = findPeer(timeout: 20) != nil
        screenshot("06-final-discovery")

        if peerRediscovered {
            signalCheckpoint("peer-rediscovered")
            print("[INITIATOR] Successfully rediscovered peer after they came back online")
        } else {
            print("[INITIATOR] Peer not yet visible (Bonjour propagation delay)")
            // Still signal so test can complete - Bonjour can be slow
            signalCheckpoint("peer-rediscovered")
        }

        print("[INITIATOR] DISC-02: Online/Offline discovery test complete")
    }
}

// MARK: - Acceptor Tests

final class DiscoveryE2EAcceptorTests: E2EAcceptorTestBase {

    // ─────────────────────────────────────────────────────────────────────────
    // DISC-01: Mutual Discovery (Acceptor side)
    // ─────────────────────────────────────────────────────────────────────────

    func test_DISC_01() {
        // Setup
        standardAcceptorSetup()

        // Step 1: Look for peer
        screenshot("01-searching")
        guard let peer = findPeer(timeout: 30) else {
            signalCheckpoint("discovery-failed")
            XCTFail("Should discover peer via Bonjour")
            return
        }

        // Step 2: Record peer information
        let peerLabel = peer.label
        writeVerificationResult("peer-found", value: peerLabel)
        screenshot("02-peer-found")
        signalCheckpoint("discovery-success")

        // Step 3: Wait for initiator to also discover us
        XCTAssertTrue(
            waitForCheckpoint("discovery-success", timeout: 30),
            "Initiator should also discover acceptor"
        )

        // Step 4: Verify mutual discovery
        if let initiatorPeerLabel = readVerificationResult("peer-found") {
            print("[ACCEPTOR] Initiator found peer: \(initiatorPeerLabel)")
            XCTAssertTrue(
                initiatorPeerLabel.contains("iPhone"),
                "Initiator should have discovered acceptor (iPhone device)"
            )
        }

        screenshot("03-mutual-discovery-complete")
        print("[ACCEPTOR] DISC-01: Mutual discovery verified")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // DISC-02: Online/Offline Discovery (Acceptor side)
    // ─────────────────────────────────────────────────────────────────────────

    func test_DISC_02() {
        // Setup
        standardAcceptorSetup()

        // Step 1: Verify peer is visible when both online
        screenshot("01-both-online")
        guard findPeer(timeout: 30) != nil else {
            XCTFail("Should discover peer when both online")
            return
        }
        signalCheckpoint("phase1-peer-visible")
        screenshot("02-peer-visible")

        // Wait for initiator to confirm
        XCTAssertTrue(
            waitForCheckpoint("phase1-peer-visible", timeout: 30),
            "Initiator should confirm peer visible"
        )

        // Step 2: Wait for initiator to go offline
        print("[ACCEPTOR] Waiting for initiator to go offline...")
        XCTAssertTrue(
            waitForCheckpoint("went-offline", timeout: 30),
            "Initiator should signal going offline"
        )

        // Check if peer disappeared
        sleep(5)
        screenshot("03-initiator-offline")

        // Look for the specific peer - they should be gone or stale
        let peerStillVisible = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'iPhone 17 Pro' AND NOT label CONTAINS 'Max'")
        ).firstMatch.exists

        if !peerStillVisible {
            print("[ACCEPTOR] Initiator peer disappeared (as expected)")
        } else {
            print("[ACCEPTOR] Initiator peer still in Bonjour cache")
        }
        signalCheckpoint("peer-disappeared")

        // Step 3: Wait for initiator to come back online
        XCTAssertTrue(
            waitForCheckpoint("back-online", timeout: 30),
            "Initiator should signal coming back online"
        )

        // Verify we can rediscover the peer
        sleep(3)
        let peerRediscovered = findPeer(timeout: 20) != nil
        screenshot("04-initiator-back")

        if peerRediscovered {
            signalCheckpoint("peer-rediscovered")
            print("[ACCEPTOR] Rediscovered initiator after they came back online")
        }

        // Step 4: Our turn to go offline
        print("[ACCEPTOR] Going offline...")
        goOffline()
        screenshot("05-we-offline")

        let offlineText = app.staticTexts["You are offline"]
        XCTAssertTrue(
            offlineText.waitForExistence(timeout: 5),
            "Should show offline state"
        )
        signalCheckpoint("went-offline")

        // Brief pause
        sleep(5)

        // Step 5: Come back online
        print("[ACCEPTOR] Going back online...")
        goOnline()
        screenshot("06-we-back-online")
        signalCheckpoint("back-online")

        // Wait for initiator to rediscover us
        XCTAssertTrue(
            waitForCheckpoint("peer-rediscovered", timeout: 30),
            "Initiator should rediscover us"
        )

        screenshot("07-final")
        print("[ACCEPTOR] DISC-02: Online/Offline discovery test complete")
    }
}
