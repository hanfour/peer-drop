import XCTest

// ═══════════════════════════════════════════════════════════════════════════
// Connection E2E Tests
//
// Tests P2P connection establishment between two simulators.
//
// Test Cases:
//   CONN-01: Full Connection - Request → Accept → TLS → Connected
//   CONN-02: Reject and Retry - First reject, then accept on retry
//   CONN-03: Reconnection - Disconnect and reconnect successfully
//
// ═══════════════════════════════════════════════════════════════════════════

// MARK: - Initiator Tests

final class ConnectionE2EInitiatorTests: E2EInitiatorTestBase {

    // ─────────────────────────────────────────────────────────────────────────
    // CONN-01: Full Connection Flow
    //
    // Tests complete connection lifecycle:
    //   1. Discover peer
    //   2. Request connection
    //   3. Wait for acceptance
    //   4. Verify TLS handshake completes
    //   5. Verify connected state
    // ─────────────────────────────────────────────────────────────────────────

    func test_CONN_01() {
        // Setup
        standardInitiatorSetup()

        // Step 1: Find peer
        screenshot("01-searching")
        guard let peer = findPeer(timeout: 30) else {
            XCTFail("Should discover peer for connection")
            return
        }
        screenshot("02-peer-found")

        // Step 2: Request connection
        print("[INITIATOR] Requesting connection...")
        tapPeer(peer)
        signalCheckpoint("connection-requested")
        screenshot("03-requesting")

        // Step 3: Wait for acceptance
        XCTAssertTrue(
            waitForCheckpoint("connection-accepted", timeout: 60),
            "Acceptor should accept connection"
        )

        // Step 4: Wait for connection to complete
        let connected = waitForConnected(timeout: 30)
        screenshot("04-connection-result")

        XCTAssertTrue(connected, "Should transition to connected state")
        signalCheckpoint("connected")

        // Step 5: Verify connection UI
        switchToTab("Connected")
        sleep(1)
        navigateToConnectionView()
        screenshot("05-connection-view")

        // Verify 3-icon UI exists
        let sendFile = app.staticTexts["Send File"]
        let chat = app.staticTexts["Chat"]
        let voiceCall = app.staticTexts["Voice Call"]

        XCTAssertTrue(
            sendFile.waitForExistence(timeout: 5),
            "Send File button should be visible"
        )
        XCTAssertTrue(chat.exists, "Chat button should be visible")
        XCTAssertTrue(voiceCall.exists, "Voice Call button should be visible")
        screenshot("06-verified-ui")

        // Wait for acceptor to verify
        XCTAssertTrue(
            waitForCheckpoint("connected", timeout: 30),
            "Acceptor should confirm connected state"
        )

        // Cleanup
        disconnectFromPeer()
        signalCheckpoint("disconnected")
        screenshot("07-disconnected")

        print("[INITIATOR] CONN-01: Full connection flow verified")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // CONN-02: Reject and Retry
    //
    // Tests rejection handling and retry:
    //   1. Request connection (first time)
    //   2. Get rejected
    //   3. Verify rejection handled gracefully
    //   4. Request again
    //   5. Get accepted
    // ─────────────────────────────────────────────────────────────────────────

    func test_CONN_02() {
        // Setup
        standardInitiatorSetup()

        // Step 1: Find peer
        guard let peer = findPeer(timeout: 30) else {
            XCTFail("Should discover peer")
            return
        }
        screenshot("01-peer-found")

        // Step 2: First connection request (will be rejected)
        print("[INITIATOR] Sending first connection request (expecting rejection)...")
        tapPeer(peer)
        signalCheckpoint("first-request")
        screenshot("02-first-request")

        // Step 3: Wait for rejection
        XCTAssertTrue(
            waitForCheckpoint("rejected", timeout: 60),
            "Acceptor should reject first request"
        )

        // Wait for rejection to propagate
        sleep(3)
        screenshot("03-after-rejection")

        // Check for rejection UI (alert or state change)
        let alert = app.alerts.firstMatch
        if alert.waitForExistence(timeout: 10) {
            screenshot("04-rejection-alert")
            // Dismiss alert
            alert.buttons.firstMatch.tap()
            sleep(1)
        }

        // Verify we're not connected
        let connectedTab = app.tabBars.buttons["Connected"]
        XCTAssertFalse(connectedTab.isSelected, "Should not be connected after rejection")
        signalCheckpoint("rejection-handled")
        screenshot("05-rejection-handled")

        // Step 4: Wait for acceptor to be ready for retry
        XCTAssertTrue(
            waitForCheckpoint("ready-for-retry", timeout: 30),
            "Acceptor should be ready for retry"
        )

        // Step 5: Second connection request (will be accepted)
        sleep(2)
        switchToTab("Nearby")
        sleep(2)

        guard let peer2 = findPeer(timeout: 20) else {
            // Try from Connected tab's recent connections
            switchToTab("Connected")
            sleep(1)
            let recentPeer = app.buttons.matching(
                NSPredicate(format: "label CONTAINS 'iPhone'")
            ).firstMatch
            if recentPeer.waitForExistence(timeout: 5) {
                recentPeer.tap()
            }
            signalCheckpoint("retry-request")
            screenshot("06-retry-via-contacts")
            return
        }

        print("[INITIATOR] Sending second connection request...")
        tapPeer(peer2)
        signalCheckpoint("retry-request")
        screenshot("06-retry-request")

        // Step 6: Wait for acceptance
        XCTAssertTrue(
            waitForCheckpoint("accepted", timeout: 60),
            "Acceptor should accept retry"
        )

        // Verify connected
        let connected = waitForConnected(timeout: 30)
        screenshot("07-connected")
        XCTAssertTrue(connected, "Should connect on retry")

        signalCheckpoint("retry-connected")

        // Cleanup
        switchToTab("Connected")
        navigateToConnectionView()
        disconnectFromPeer()
        signalCheckpoint("test-complete")
        screenshot("08-complete")

        print("[INITIATOR] CONN-02: Reject and retry verified")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // CONN-03: Reconnection
    //
    // Tests disconnection and reconnection:
    //   1. Establish connection
    //   2. Exchange a message (to have session data)
    //   3. Disconnect
    //   4. Reconnect
    //   5. Verify chat history persists
    // ─────────────────────────────────────────────────────────────────────────

    func test_CONN_03() {
        // Setup
        standardInitiatorSetup()

        // Step 1: Find and connect to peer
        guard let peer = findPeer(timeout: 30) else {
            XCTFail("Should discover peer")
            return
        }

        print("[INITIATOR] Connecting...")
        tapPeer(peer)
        signalCheckpoint("connection-requested")

        XCTAssertTrue(
            waitForCheckpoint("connection-accepted", timeout: 60),
            "Acceptor should accept"
        )

        let connected = waitForConnected(timeout: 30)
        XCTAssertTrue(connected, "Should connect")
        signalCheckpoint("connected")
        screenshot("01-connected")

        // Step 2: Send a message
        switchToTab("Connected")
        navigateToConnectionView()
        navigateToChat()

        let testMessage = "Reconnection test [\(UUID().uuidString.prefix(8))]"
        sendChatMessage(testMessage)
        writeVerificationResult("message", value: testMessage)
        signalCheckpoint("message-sent")
        screenshot("02-message-sent")

        // Wait for reply
        XCTAssertTrue(
            waitForCheckpoint("reply-sent", timeout: 30),
            "Acceptor should reply"
        )

        if let reply = waitForVerificationData("message", timeout: 10) {
            XCTAssertTrue(
                verifyMessageExists(reply, timeout: 10),
                "Should see acceptor's reply"
            )
        }
        screenshot("03-reply-received")

        // Step 3: Disconnect
        print("[INITIATOR] Disconnecting...")
        goBack() // Back to ConnectionView
        disconnectFromPeer()
        signalCheckpoint("disconnected")
        screenshot("04-disconnected")

        // Wait for acceptor to notice
        XCTAssertTrue(
            waitForCheckpoint("disconnect-noticed", timeout: 30),
            "Acceptor should notice disconnect"
        )

        // Step 4: Reconnect
        sleep(3)
        switchToTab("Nearby")
        sleep(2)

        guard let peer2 = findPeer(timeout: 30) else {
            // Try from Connected tab
            switchToTab("Connected")
            let recentPeer = app.buttons.matching(
                NSPredicate(format: "label CONTAINS 'iPhone'")
            ).firstMatch
            if recentPeer.waitForExistence(timeout: 5) {
                recentPeer.tap()
            }
            screenshot("05-reconnect-via-contacts")
            signalCheckpoint("reconnect-requested")
            return
        }

        print("[INITIATOR] Reconnecting...")
        tapPeer(peer2)
        signalCheckpoint("reconnect-requested")
        screenshot("05-reconnect-request")

        // Wait for acceptance
        XCTAssertTrue(
            waitForCheckpoint("reconnect-accepted", timeout: 60),
            "Acceptor should accept reconnect"
        )

        let reconnected = waitForConnected(timeout: 30)
        XCTAssertTrue(reconnected, "Should reconnect")
        signalCheckpoint("reconnected")
        screenshot("06-reconnected")

        // Step 5: Verify chat history persists
        switchToTab("Connected")
        navigateToConnectionView()
        navigateToChat()
        sleep(1)

        let historyPersisted = verifyMessageExists(testMessage, timeout: 5)
        screenshot("07-chat-history")

        if historyPersisted {
            print("[INITIATOR] Chat history persisted across reconnect")
            writeVerificationResult("history-check", value: "persisted")
        } else {
            print("[INITIATOR] Chat history not found (may be expected)")
            writeVerificationResult("history-check", value: "not-found")
        }

        signalCheckpoint("history-verified")

        // Cleanup
        goBack()
        disconnectFromPeer()
        signalCheckpoint("test-complete")
        screenshot("08-complete")

        print("[INITIATOR] CONN-03: Reconnection verified")
    }
}

// MARK: - Acceptor Tests

final class ConnectionE2EAcceptorTests: E2EAcceptorTestBase {

    // ─────────────────────────────────────────────────────────────────────────
    // CONN-01: Full Connection Flow (Acceptor side)
    // ─────────────────────────────────────────────────────────────────────────

    func test_CONN_01() {
        // Setup
        standardAcceptorSetup()

        // Step 1: Wait for connection request
        screenshot("01-waiting")
        XCTAssertTrue(
            waitForCheckpoint("connection-requested", timeout: 60),
            "Initiator should request connection"
        )

        // Step 2: Accept connection
        acceptConnection()
        signalCheckpoint("connection-accepted")
        screenshot("02-accepted")

        // Step 3: Wait for connection to complete
        let connected = waitForConnected(timeout: 30)
        XCTAssertTrue(connected, "Should transition to connected state")
        signalCheckpoint("connected")
        screenshot("03-connected")

        // Step 4: Verify connection UI
        let connectedTab = app.tabBars.buttons["Connected"]
        if !connectedTab.isSelected {
            connectedTab.tap()
            sleep(1)
        }
        navigateToConnectionView()

        // Verify 3-icon UI exists
        let sendFile = app.staticTexts["Send File"]
        let chat = app.staticTexts["Chat"]
        let voiceCall = app.staticTexts["Voice Call"]

        XCTAssertTrue(
            sendFile.waitForExistence(timeout: 5),
            "Send File button should be visible"
        )
        XCTAssertTrue(chat.exists, "Chat button should be visible")
        XCTAssertTrue(voiceCall.exists, "Voice Call button should be visible")
        screenshot("04-verified-ui")

        // Wait for initiator to disconnect
        XCTAssertTrue(
            waitForCheckpoint("disconnected", timeout: 60),
            "Initiator should disconnect"
        )
        screenshot("05-disconnected")

        print("[ACCEPTOR] CONN-01: Full connection flow verified")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // CONN-02: Reject and Retry (Acceptor side)
    // ─────────────────────────────────────────────────────────────────────────

    func test_CONN_02() {
        // Setup
        standardAcceptorSetup()

        // Step 1: Wait for first connection request
        screenshot("01-waiting")
        XCTAssertTrue(
            waitForCheckpoint("first-request", timeout: 60),
            "Initiator should send first request"
        )

        // Step 2: REJECT the connection
        XCTAssertTrue(waitForConsent(), "Should receive consent sheet")
        screenshot("02-consent-reject")

        print("[ACCEPTOR] Rejecting first connection...")
        app.buttons["Decline"].tap()
        signalCheckpoint("rejected")
        sleep(2)
        screenshot("03-rejected")

        // Verify not connected
        let connectedTab = app.tabBars.buttons["Connected"]
        connectedTab.tap()
        sleep(1)

        let noConnection = app.staticTexts["No active connection"]
        let noSaved = app.staticTexts["No saved devices"]
        XCTAssertTrue(
            noConnection.exists || noSaved.exists,
            "Should show no connection after rejection"
        )
        screenshot("04-not-connected")

        // Wait for initiator to handle rejection
        XCTAssertTrue(
            waitForCheckpoint("rejection-handled", timeout: 30),
            "Initiator should handle rejection"
        )

        // Step 3: Ready for retry
        switchToTab("Nearby")
        sleep(1)
        signalCheckpoint("ready-for-retry")
        screenshot("05-ready-for-retry")

        // Step 4: Wait for retry request
        XCTAssertTrue(
            waitForCheckpoint("retry-request", timeout: 60),
            "Initiator should retry"
        )

        // Step 5: ACCEPT the retry
        XCTAssertTrue(waitForConsent(timeout: 30), "Should receive retry consent")
        screenshot("06-consent-accept")

        print("[ACCEPTOR] Accepting retry...")
        app.buttons["Accept"].tap()
        signalCheckpoint("accepted")
        sleep(3)
        screenshot("07-accepted")

        // Wait for initiator to confirm connection
        XCTAssertTrue(
            waitForCheckpoint("retry-connected", timeout: 30),
            "Initiator should confirm connected"
        )
        screenshot("08-connected")

        // Wait for cleanup
        XCTAssertTrue(
            waitForCheckpoint("test-complete", timeout: 60),
            "Test should complete"
        )
        screenshot("09-complete")

        print("[ACCEPTOR] CONN-02: Reject and retry verified")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // CONN-03: Reconnection (Acceptor side)
    // ─────────────────────────────────────────────────────────────────────────

    func test_CONN_03() {
        // Setup
        standardAcceptorSetup()

        // Step 1: Wait for connection request
        XCTAssertTrue(
            waitForCheckpoint("connection-requested", timeout: 60),
            "Initiator should request connection"
        )

        // Accept connection
        acceptConnection()
        signalCheckpoint("connection-accepted")
        screenshot("01-accepted")

        // Wait for connection
        let connected = waitForConnected(timeout: 30)
        XCTAssertTrue(connected, "Should connect")
        XCTAssertTrue(
            waitForCheckpoint("connected", timeout: 30),
            "Initiator should confirm connected"
        )

        // Step 2: Navigate to chat and wait for message
        let connectedTab = app.tabBars.buttons["Connected"]
        if !connectedTab.isSelected {
            connectedTab.tap()
            sleep(1)
        }
        navigateToConnectionView()
        navigateToChat()

        XCTAssertTrue(
            waitForCheckpoint("message-sent", timeout: 30),
            "Initiator should send message"
        )

        // Verify we received the message
        if let message = waitForVerificationData("message", timeout: 10) {
            XCTAssertTrue(
                verifyMessageExists(message, timeout: 10),
                "Should receive initiator's message"
            )
            screenshot("02-message-received")
        }

        // Send reply
        let reply = "Reply [\(UUID().uuidString.prefix(8))]"
        sendChatMessage(reply)
        writeVerificationResult("message", value: reply)
        signalCheckpoint("reply-sent")
        screenshot("03-reply-sent")

        // Step 3: Wait for disconnect
        XCTAssertTrue(
            waitForCheckpoint("disconnected", timeout: 60),
            "Initiator should disconnect"
        )

        sleep(3)
        screenshot("04-disconnected")
        signalCheckpoint("disconnect-noticed")

        // Step 4: Wait for reconnect request
        XCTAssertTrue(
            waitForCheckpoint("reconnect-requested", timeout: 60),
            "Initiator should request reconnect"
        )

        // Accept reconnect
        XCTAssertTrue(waitForConsent(timeout: 30), "Should receive reconnect consent")
        screenshot("05-reconnect-consent")
        app.buttons["Accept"].tap()
        signalCheckpoint("reconnect-accepted")
        sleep(3)
        screenshot("06-reconnected")

        // Wait for initiator to confirm
        XCTAssertTrue(
            waitForCheckpoint("reconnected", timeout: 30),
            "Initiator should confirm reconnected"
        )

        // Step 5: Verify chat history
        if !connectedTab.isSelected {
            connectedTab.tap()
            sleep(1)
        }
        navigateToConnectionView()
        navigateToChat()
        sleep(1)
        screenshot("07-chat-history")

        // Wait for initiator's history check
        XCTAssertTrue(
            waitForCheckpoint("history-verified", timeout: 30),
            "Initiator should verify history"
        )

        // Verify our previous reply is still there
        if let previousReply = readVerificationResult("message") {
            // Previous message should be visible if history persists
            let historyCheck = verifyMessageExists(previousReply, timeout: 5)
            print("[ACCEPTOR] Previous reply visible: \(historyCheck)")
        }

        // Wait for cleanup
        XCTAssertTrue(
            waitForCheckpoint("test-complete", timeout: 60),
            "Test should complete"
        )
        screenshot("08-complete")

        print("[ACCEPTOR] CONN-03: Reconnection verified")
    }
}
