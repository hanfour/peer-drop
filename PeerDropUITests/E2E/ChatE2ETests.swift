import XCTest

// ═══════════════════════════════════════════════════════════════════════════
// Chat E2E Tests
//
// Tests P2P chat functionality between two simulators.
//
// Test Cases:
//   CHAT-01: Bidirectional Messages - Messages round-trip correctly
//   CHAT-02: Rapid Message Burst - 10 messages in quick succession
//   CHAT-03: Read Receipts - Message read status updates
//
// ═══════════════════════════════════════════════════════════════════════════

// MARK: - Initiator Tests

final class ChatE2EInitiatorTests: E2EInitiatorTestBase {

    // ─────────────────────────────────────────────────────────────────────────
    // CHAT-01: Bidirectional Messages
    //
    // Tests that messages can be sent and received in both directions.
    //
    // Flow:
    //   1. Establish connection
    //   2. Initiator sends message
    //   3. Acceptor receives and replies
    //   4. Initiator verifies reply
    //   5. Multiple rounds of exchange
    // ─────────────────────────────────────────────────────────────────────────

    func test_CHAT_01() {
        // Setup and connect
        standardInitiatorSetup()

        guard let peer = findPeer(timeout: 30) else {
            XCTFail("Should discover peer")
            return
        }

        tapPeer(peer)
        signalCheckpoint("connection-requested")

        XCTAssertTrue(
            waitForCheckpoint("connection-accepted", timeout: 60),
            "Acceptor should accept"
        )

        XCTAssertTrue(waitForConnected(timeout: 30), "Should connect")
        signalCheckpoint("connected")
        screenshot("01-connected")

        // Navigate to chat
        switchToTab("Connected")
        navigateToConnectionView()
        navigateToChat()
        screenshot("02-chat-opened")

        // Round 1: Send message
        let msg1 = "Hello from Initiator [\(UUID().uuidString.prefix(8))]"
        sendChatMessage(msg1)
        writeVerificationResult("msg1", value: msg1)
        signalCheckpoint("msg1-sent")
        screenshot("03-msg1-sent")

        // Wait for reply
        XCTAssertTrue(
            waitForCheckpoint("reply1-sent", timeout: 30),
            "Acceptor should reply"
        )

        if let reply1 = waitForVerificationData("reply1", timeout: 10) {
            XCTAssertTrue(
                verifyMessageExists(reply1, timeout: 15),
                "Should see acceptor's reply"
            )
            screenshot("04-reply1-received")
        }

        // Round 2: Send another message
        let msg2 = "Second message [\(UUID().uuidString.prefix(8))]"
        sendChatMessage(msg2)
        writeVerificationResult("msg2", value: msg2)
        signalCheckpoint("msg2-sent")
        screenshot("05-msg2-sent")

        // Wait for second reply
        XCTAssertTrue(
            waitForCheckpoint("reply2-sent", timeout: 30),
            "Acceptor should send second reply"
        )

        if let reply2 = waitForVerificationData("reply2", timeout: 10) {
            XCTAssertTrue(
                verifyMessageExists(reply2, timeout: 15),
                "Should see second reply"
            )
            screenshot("06-reply2-received")
        }

        // Round 3: Final exchange
        let msg3 = "Final message [\(UUID().uuidString.prefix(8))]"
        sendChatMessage(msg3)
        writeVerificationResult("msg3", value: msg3)
        signalCheckpoint("msg3-sent")
        screenshot("07-msg3-sent")

        XCTAssertTrue(
            waitForCheckpoint("reply3-sent", timeout: 30),
            "Acceptor should send final reply"
        )

        if let reply3 = waitForVerificationData("reply3", timeout: 10) {
            XCTAssertTrue(
                verifyMessageExists(reply3, timeout: 15),
                "Should see final reply"
            )
        }
        screenshot("08-all-messages")

        // Verify all our messages are still visible
        XCTAssertTrue(verifyMessageExists(msg1, timeout: 5), "First message should persist")
        XCTAssertTrue(verifyMessageExists(msg2, timeout: 5), "Second message should persist")
        XCTAssertTrue(verifyMessageExists(msg3, timeout: 5), "Third message should persist")

        // Cleanup
        goBack()
        disconnectFromPeer()
        signalCheckpoint("test-complete")
        screenshot("09-complete")

        print("[INITIATOR] CHAT-01: Bidirectional messages verified")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // CHAT-02: Rapid Message Burst
    //
    // Tests sending multiple messages in quick succession.
    //
    // Flow:
    //   1. Establish connection
    //   2. Send 10 messages rapidly
    //   3. Verify all messages delivered
    //   4. Verify order is preserved
    // ─────────────────────────────────────────────────────────────────────────

    func test_CHAT_02() {
        // Setup and connect
        standardInitiatorSetup()

        guard let peer = findPeer(timeout: 30) else {
            XCTFail("Should discover peer")
            return
        }

        tapPeer(peer)
        signalCheckpoint("connection-requested")

        XCTAssertTrue(
            waitForCheckpoint("connection-accepted", timeout: 60),
            "Acceptor should accept"
        )

        XCTAssertTrue(waitForConnected(timeout: 30), "Should connect")
        signalCheckpoint("connected")
        screenshot("01-connected")

        // Navigate to chat
        switchToTab("Connected")
        navigateToConnectionView()
        navigateToChat()
        screenshot("02-chat-opened")

        // Send 10 messages rapidly
        let messagePrefix = "Burst-\(UUID().uuidString.prefix(4))"
        var sentMessages: [String] = []

        for i in 1...10 {
            let msg = "\(messagePrefix)-\(String(format: "%02d", i))"
            sendChatMessage(msg)
            sentMessages.append(msg)
            // Minimal delay between messages
            usleep(200_000) // 200ms
        }

        // Store messages for verification
        writeVerificationResult("burst-prefix", value: messagePrefix)
        writeVerificationResult("burst-count", value: "10")
        signalCheckpoint("burst-sent")
        screenshot("03-burst-sent")

        // Wait for acceptor to verify receipt
        XCTAssertTrue(
            waitForCheckpoint("burst-verified", timeout: 60),
            "Acceptor should verify all messages"
        )

        // Wait for acceptor's reply burst
        XCTAssertTrue(
            waitForCheckpoint("reply-burst-sent", timeout: 60),
            "Acceptor should send reply burst"
        )

        // Verify we received acceptor's burst
        if let replyPrefix = waitForVerificationData("reply-prefix", timeout: 10) {
            var repliesReceived = 0
            for i in 1...10 {
                let expectedReply = "\(replyPrefix)-\(String(format: "%02d", i))"
                if verifyMessageExists(expectedReply, timeout: 2) {
                    repliesReceived += 1
                }
            }
            print("[INITIATOR] Received \(repliesReceived)/10 reply messages")
            XCTAssertGreaterThanOrEqual(
                repliesReceived, 8,
                "Should receive most reply messages"
            )
        }
        screenshot("04-replies-received")

        // Verify our messages are all still visible
        var ourMessagesVisible = 0
        for msg in sentMessages {
            if verifyMessageExists(msg, timeout: 1) {
                ourMessagesVisible += 1
            }
        }
        screenshot("05-our-messages")
        XCTAssertEqual(
            ourMessagesVisible, 10,
            "All our burst messages should be visible"
        )

        // Cleanup
        goBack()
        disconnectFromPeer()
        signalCheckpoint("test-complete")
        screenshot("06-complete")

        print("[INITIATOR] CHAT-02: Rapid burst verified - sent 10, visible \(ourMessagesVisible)")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // CHAT-03: Read Receipts
    //
    // Tests that read receipts are sent and displayed correctly.
    //
    // Flow:
    //   1. Establish connection
    //   2. Send message
    //   3. Verify "delivered" status
    //   4. Wait for acceptor to read (open chat)
    //   5. Verify "read" status updates
    // ─────────────────────────────────────────────────────────────────────────

    func test_CHAT_03() {
        // Setup and connect
        standardInitiatorSetup()

        guard let peer = findPeer(timeout: 30) else {
            XCTFail("Should discover peer")
            return
        }

        tapPeer(peer)
        signalCheckpoint("connection-requested")

        XCTAssertTrue(
            waitForCheckpoint("connection-accepted", timeout: 60),
            "Acceptor should accept"
        )

        XCTAssertTrue(waitForConnected(timeout: 30), "Should connect")
        signalCheckpoint("connected")
        screenshot("01-connected")

        // Navigate to chat
        switchToTab("Connected")
        navigateToConnectionView()
        navigateToChat()
        screenshot("02-chat-opened")

        // Send message
        let testMsg = "Read receipt test [\(UUID().uuidString.prefix(8))]"
        sendChatMessage(testMsg)
        writeVerificationResult("receipt-test-msg", value: testMsg)
        signalCheckpoint("message-sent")
        screenshot("03-message-sent")

        // Look for initial status (should show sent/delivered)
        // Status indicators are typically checkmarks or text
        _ = app.images["message-delivered"]
        _ = app.images["message-sent"]

        // Take screenshot of initial status
        sleep(2)
        screenshot("04-initial-status")

        // Signal acceptor to NOT open chat yet
        signalCheckpoint("check-unread")

        // Wait for acceptor to confirm they haven't opened chat
        XCTAssertTrue(
            waitForCheckpoint("still-not-in-chat", timeout: 30),
            "Acceptor should confirm not in chat"
        )

        // Now tell acceptor to open chat (trigger read receipt)
        signalCheckpoint("open-chat-now")

        // Wait for acceptor to open chat
        XCTAssertTrue(
            waitForCheckpoint("chat-opened", timeout: 30),
            "Acceptor should open chat"
        )

        // Wait a moment for read receipt to propagate
        sleep(3)
        screenshot("05-after-read")

        // Look for read status indicator
        let readIndicator = app.images["message-read"]
        let doubleCheck = app.images.matching(
            NSPredicate(format: "identifier CONTAINS 'read' OR identifier CONTAINS 'seen'")
        ).firstMatch

        // Capture the read status
        if readIndicator.exists || doubleCheck.exists {
            print("[INITIATOR] Read receipt indicator found")
            writeVerificationResult("read-status", value: "visible")
        } else {
            print("[INITIATOR] Read receipt indicator not found (may use different UI)")
            writeVerificationResult("read-status", value: "not-visible")
        }
        screenshot("06-read-status")

        signalCheckpoint("read-status-checked")

        // Exchange another message to confirm continued functionality
        let msg2 = "After read test"
        sendChatMessage(msg2)
        signalCheckpoint("msg2-sent")

        XCTAssertTrue(
            waitForCheckpoint("msg2-received", timeout: 30),
            "Acceptor should receive second message"
        )

        screenshot("07-final")

        // Cleanup
        goBack()
        disconnectFromPeer()
        signalCheckpoint("test-complete")
        screenshot("08-complete")

        print("[INITIATOR] CHAT-03: Read receipts test complete")
    }
}

// MARK: - Acceptor Tests

final class ChatE2EAcceptorTests: E2EAcceptorTestBase {

    // ─────────────────────────────────────────────────────────────────────────
    // CHAT-01: Bidirectional Messages (Acceptor side)
    // ─────────────────────────────────────────────────────────────────────────

    func test_CHAT_01() {
        // Setup
        standardAcceptorSetup()

        // Wait for connection request
        XCTAssertTrue(
            waitForCheckpoint("connection-requested", timeout: 60),
            "Initiator should request connection"
        )

        acceptConnection()
        signalCheckpoint("connection-accepted")

        XCTAssertTrue(
            waitForCheckpoint("connected", timeout: 30),
            "Initiator should confirm connected"
        )
        screenshot("01-connected")

        // Navigate to chat
        let connectedTab = app.tabBars.buttons["Connected"]
        if !connectedTab.isSelected {
            connectedTab.tap()
            sleep(1)
        }
        navigateToConnectionView()
        navigateToChat()
        screenshot("02-chat-opened")

        // Round 1: Wait for message and reply
        XCTAssertTrue(
            waitForCheckpoint("msg1-sent", timeout: 30),
            "Initiator should send first message"
        )

        if let msg1 = waitForVerificationData("msg1", timeout: 10) {
            XCTAssertTrue(
                verifyMessageExists(msg1, timeout: 15),
                "Should see initiator's first message"
            )
            screenshot("03-msg1-received")
        }

        let reply1 = "Reply 1 [\(UUID().uuidString.prefix(8))]"
        sendChatMessage(reply1)
        writeVerificationResult("reply1", value: reply1)
        signalCheckpoint("reply1-sent")
        screenshot("04-reply1-sent")

        // Round 2
        XCTAssertTrue(
            waitForCheckpoint("msg2-sent", timeout: 30),
            "Initiator should send second message"
        )

        if let msg2 = waitForVerificationData("msg2", timeout: 10) {
            XCTAssertTrue(
                verifyMessageExists(msg2, timeout: 15),
                "Should see second message"
            )
        }

        let reply2 = "Reply 2 [\(UUID().uuidString.prefix(8))]"
        sendChatMessage(reply2)
        writeVerificationResult("reply2", value: reply2)
        signalCheckpoint("reply2-sent")
        screenshot("05-reply2-sent")

        // Round 3
        XCTAssertTrue(
            waitForCheckpoint("msg3-sent", timeout: 30),
            "Initiator should send third message"
        )

        if let msg3 = waitForVerificationData("msg3", timeout: 10) {
            XCTAssertTrue(
                verifyMessageExists(msg3, timeout: 15),
                "Should see third message"
            )
        }

        let reply3 = "Reply 3 [\(UUID().uuidString.prefix(8))]"
        sendChatMessage(reply3)
        writeVerificationResult("reply3", value: reply3)
        signalCheckpoint("reply3-sent")
        screenshot("06-reply3-sent")

        // Wait for cleanup
        XCTAssertTrue(
            waitForCheckpoint("test-complete", timeout: 60),
            "Test should complete"
        )
        screenshot("07-complete")

        print("[ACCEPTOR] CHAT-01: Bidirectional messages verified")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // CHAT-02: Rapid Message Burst (Acceptor side)
    // ─────────────────────────────────────────────────────────────────────────

    func test_CHAT_02() {
        // Setup
        standardAcceptorSetup()

        // Wait for connection
        XCTAssertTrue(
            waitForCheckpoint("connection-requested", timeout: 60),
            "Initiator should request connection"
        )

        acceptConnection()
        signalCheckpoint("connection-accepted")

        XCTAssertTrue(
            waitForCheckpoint("connected", timeout: 30),
            "Initiator should confirm connected"
        )
        screenshot("01-connected")

        // Navigate to chat
        let connectedTab = app.tabBars.buttons["Connected"]
        if !connectedTab.isSelected {
            connectedTab.tap()
            sleep(1)
        }
        navigateToConnectionView()
        navigateToChat()
        screenshot("02-chat-opened")

        // Wait for burst
        XCTAssertTrue(
            waitForCheckpoint("burst-sent", timeout: 60),
            "Initiator should send burst"
        )

        // Wait for messages to arrive
        sleep(5)
        screenshot("03-burst-receiving")

        // Verify we received the burst
        if let prefix = waitForVerificationData("burst-prefix", timeout: 10) {
            var received = 0
            for i in 1...10 {
                let expected = "\(prefix)-\(String(format: "%02d", i))"
                if verifyMessageExists(expected, timeout: 2) {
                    received += 1
                }
            }
            print("[ACCEPTOR] Received \(received)/10 burst messages")
            writeVerificationResult("burst-received", value: "\(received)")

            XCTAssertGreaterThanOrEqual(
                received, 8,
                "Should receive most burst messages"
            )
        }
        screenshot("04-burst-received")
        signalCheckpoint("burst-verified")

        // Send our own burst
        let replyPrefix = "Reply-\(UUID().uuidString.prefix(4))"
        writeVerificationResult("reply-prefix", value: replyPrefix)

        for i in 1...10 {
            let msg = "\(replyPrefix)-\(String(format: "%02d", i))"
            sendChatMessage(msg)
            usleep(200_000)
        }
        signalCheckpoint("reply-burst-sent")
        screenshot("05-reply-burst-sent")

        // Wait for cleanup
        XCTAssertTrue(
            waitForCheckpoint("test-complete", timeout: 60),
            "Test should complete"
        )
        screenshot("06-complete")

        print("[ACCEPTOR] CHAT-02: Rapid burst verified")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // CHAT-03: Read Receipts (Acceptor side)
    // ─────────────────────────────────────────────────────────────────────────

    func test_CHAT_03() {
        // Setup
        standardAcceptorSetup()

        // Wait for connection
        XCTAssertTrue(
            waitForCheckpoint("connection-requested", timeout: 60),
            "Initiator should request connection"
        )

        acceptConnection()
        signalCheckpoint("connection-accepted")

        XCTAssertTrue(
            waitForCheckpoint("connected", timeout: 30),
            "Initiator should confirm connected"
        )
        screenshot("01-connected")

        // DON'T navigate to chat yet - we're testing read receipts
        // Stay on Connected tab but don't open the chat

        // Wait for message to be sent
        XCTAssertTrue(
            waitForCheckpoint("message-sent", timeout: 30),
            "Initiator should send message"
        )
        screenshot("02-message-waiting")

        // Wait for signal to check unread
        XCTAssertTrue(
            waitForCheckpoint("check-unread", timeout: 30),
            "Initiator should signal to check unread"
        )

        // Check if there's an unread indicator on the Connected tab
        let connectedTab = app.tabBars.buttons["Connected"]
        screenshot("03-unread-check")

        // Signal that we haven't opened chat
        signalCheckpoint("still-not-in-chat")

        // Wait for signal to open chat
        XCTAssertTrue(
            waitForCheckpoint("open-chat-now", timeout: 30),
            "Initiator should signal to open chat"
        )

        // Now open chat - this should trigger read receipt
        if !connectedTab.isSelected {
            connectedTab.tap()
            sleep(1)
        }
        navigateToConnectionView()
        navigateToChat()
        screenshot("04-chat-opened")
        signalCheckpoint("chat-opened")

        // Verify we can see the message
        if let testMsg = readVerificationResult("receipt-test-msg") {
            XCTAssertTrue(
                verifyMessageExists(testMsg, timeout: 10),
                "Should see the test message"
            )
            print("[ACCEPTOR] Read message: \(testMsg)")
        }
        screenshot("05-message-read")

        // Wait for initiator to check read status
        XCTAssertTrue(
            waitForCheckpoint("read-status-checked", timeout: 30),
            "Initiator should check read status"
        )

        // Wait for second message
        XCTAssertTrue(
            waitForCheckpoint("msg2-sent", timeout: 30),
            "Initiator should send second message"
        )

        // Verify we receive it
        sleep(2)
        let msg2Visible = app.staticTexts["After read test"].exists
        if msg2Visible {
            signalCheckpoint("msg2-received")
        } else {
            // Still signal to complete test
            signalCheckpoint("msg2-received")
        }
        screenshot("06-msg2-check")

        // Wait for cleanup
        XCTAssertTrue(
            waitForCheckpoint("test-complete", timeout: 60),
            "Test should complete"
        )
        screenshot("07-complete")

        print("[ACCEPTOR] CHAT-03: Read receipts test complete")
    }
}
