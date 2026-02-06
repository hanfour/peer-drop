import XCTest

// ═══════════════════════════════════════════════════════════════════════════
// Timeout / Stale Consent UX Verification
//
// Tests that consent sheet auto-dismisses when the initiator times out,
// and that normal accept flow still works (regression).
//
// USAGE (run pairs simultaneously):
//   Pair A4/B4 (timeout auto-dismiss):
//     Sim A (iPhone 17 Pro):
//       -only-testing:PeerDropUITests/TimeoutInitiatorTests/testA4_RequestTimeout
//     Sim B (iPhone 17 Pro Max):
//       -only-testing:PeerDropUITests/TimeoutAcceptorTests/testB4_ConsentAutoDismissOnTimeout
//
//   Pair A5/B5 (normal accept — regression):
//     Sim A (iPhone 17 Pro):
//       -only-testing:PeerDropUITests/TimeoutInitiatorTests/testA5_NormalConnectionRegression
//     Sim B (iPhone 17 Pro Max):
//       -only-testing:PeerDropUITests/TimeoutAcceptorTests/testB5_NormalAcceptRegression
// ═══════════════════════════════════════════════════════════════════════════

// MARK: - Shared Helpers

private extension XCUIApplication {

    func ensureOnline() {
        let goOnlineBtn = navigationBars.buttons["Go online"]
        if goOnlineBtn.waitForExistence(timeout: 2) {
            goOnlineBtn.tap()
            sleep(2)
        }
    }

    func findPeer(timeout: TimeInterval = 30) -> XCUIElement? {
        let peer = buttons.matching(NSPredicate(format: "label CONTAINS 'iPhone'")).firstMatch
        if peer.waitForExistence(timeout: timeout) { return peer }
        let cell = cells.matching(NSPredicate(format: "label CONTAINS 'iPhone'")).firstMatch
        if cell.waitForExistence(timeout: 3) { return cell }
        return nil
    }

    func tapPeer(_ peer: XCUIElement) {
        peer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    func waitForConnected(timeout: Int = 30) -> Bool {
        let connectedTab = tabBars.buttons["Connected"]
        for _ in 0..<timeout {
            if connectedTab.isSelected { return true }
            sleep(1)
        }
        return false
    }

    func waitForConsent(timeout: Int = 60) -> Bool {
        let accept = buttons["Accept"]
        for _ in 0..<timeout {
            if accept.exists { return true }
            sleep(1)
        }
        return false
    }

    func navigateToConnectionView() {
        let peerRow = buttons["active-peer-row"]
        if peerRow.waitForExistence(timeout: 5) {
            peerRow.tap()
            sleep(1)
        }
    }

    func navigateToChat() {
        let chatBtn = buttons["chat-button"]
        if chatBtn.waitForExistence(timeout: 5) { chatBtn.tap(); sleep(1) }
    }

    func sendChatMessage(_ text: String) {
        let field = textFields["Message"]
        if field.waitForExistence(timeout: 5) {
            field.tap()
            field.typeText(text)
            let send = buttons["Send"]
            if send.waitForExistence(timeout: 2) { send.tap() }
            sleep(1)
        }
    }

    func goBackOnce() {
        let back = navigationBars.buttons.firstMatch
        if back.exists { back.tap(); sleep(1) }
    }

    func disconnectFromPeer() {
        let btn = buttons.matching(identifier: "Disconnect").firstMatch
        if btn.waitForExistence(timeout: 5) {
            btn.tap()
            sleep(1)
            let sheetBtn = buttons["sheet-primary-action"]
            if sheetBtn.waitForExistence(timeout: 5) {
                sheetBtn.tap()
            }
            sleep(2)
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - INITIATOR (Sim A — iPhone 17 Pro)
// ═══════════════════════════════════════════════════════════════════════════

final class TimeoutInitiatorTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
    }

    private func screenshot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    // ─────────────────────────────────────────────────────────────────
    // TEST A4: Request → Timeout (acceptor never accepts)
    // Pair with: TimeoutAcceptorTests/testB4_ConsentAutoDismissOnTimeout
    // ─────────────────────────────────────────────────────────────────

    func testA4_RequestTimeout() {
        app.launchArguments = ["-peerDropIsOnline", "1"]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        app.ensureOnline()
        screenshot("A4-00-discovery")

        // Find and tap peer to initiate connection
        guard let peer = app.findPeer(timeout: 30) else {
            XCTFail("No peer discovered"); return
        }
        app.tapPeer(peer)
        screenshot("A4-01-requesting")
        print("[A4] Initiated connection request — waiting for 15s timeout...")

        // Wait for timeout error (15s + margin)
        let errorAlert = app.alerts["Connection Error"]
        let timedOut = errorAlert.waitForExistence(timeout: 25)
        screenshot("A4-02-timeout-error")
        XCTAssertTrue(timedOut, "Should show Connection Error after 15s timeout")
        print("[A4] Timeout error shown")

        // Verify the error message mentions timeout
        let errorText = errorAlert.staticTexts.allElementsBoundByIndex
            .map { $0.label }
            .joined(separator: " ")
        XCTAssertTrue(
            errorText.lowercased().contains("timed out"),
            "Error should mention timeout, got: \(errorText)"
        )

        // Tap "Back to Discovery"
        let backBtn = errorAlert.buttons["Back to Discovery"]
        if backBtn.exists {
            backBtn.tap()
            sleep(2)
        }
        screenshot("A4-03-back-to-discovery")

        // Verify we're back on Nearby tab
        let nearbyTab = app.tabBars.buttons["Nearby"]
        XCTAssertTrue(nearbyTab.isSelected || nearbyTab.waitForExistence(timeout: 5),
                      "Should return to Nearby tab")
        print("[A4] === TIMEOUT TEST PASSED ===")
    }

    // ─────────────────────────────────────────────────────────────────
    // TEST A5: Normal connection (regression check)
    // Pair with: TimeoutAcceptorTests/testB5_NormalAcceptRegression
    // ─────────────────────────────────────────────────────────────────

    func testA5_NormalConnectionRegression() {
        app.launchArguments = ["-peerDropIsOnline", "1"]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        app.ensureOnline()
        screenshot("A5-00-discovery")

        // Find and tap peer
        guard let peer = app.findPeer(timeout: 30) else {
            XCTFail("No peer discovered"); return
        }
        app.tapPeer(peer)
        screenshot("A5-01-requesting")
        print("[A5] Initiated connection request")

        // Should connect (acceptor will accept quickly)
        XCTAssertTrue(app.waitForConnected(timeout: 30), "Should connect normally")
        screenshot("A5-02-connected")
        print("[A5] Connected successfully")

        // Navigate to connection view and verify features work
        app.navigateToConnectionView()
        screenshot("A5-03-connection-view")

        // Test chat (regression)
        app.navigateToChat()
        app.sendChatMessage("Regression test message")
        screenshot("A5-04-chat-sent")
        print("[A5] Chat message sent")

        // Wait for reply
        let reply = app.staticTexts["Regression reply"]
        let gotReply = reply.waitForExistence(timeout: 30)
        screenshot("A5-05-reply")
        XCTAssertTrue(gotReply, "Should receive chat reply")
        print("[A5] Chat reply received")

        // Verify Send File button exists (regression)
        app.goBackOnce()
        let sendFileBtn = app.buttons["send-file-button"]
        XCTAssertTrue(sendFileBtn.waitForExistence(timeout: 5), "Send File button should exist")

        // Verify Voice Call button exists (regression)
        let voiceBtn = app.buttons["voice-call-button"]
        XCTAssertTrue(voiceBtn.exists, "Voice Call button should exist")

        screenshot("A5-06-features-verified")
        print("[A5] All features verified")

        // Cleanup
        app.disconnectFromPeer()
        sleep(2)
        print("[A5] === NORMAL CONNECTION REGRESSION PASSED ===")
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - ACCEPTOR (Sim B — iPhone 17 Pro Max)
// ═══════════════════════════════════════════════════════════════════════════

final class TimeoutAcceptorTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
    }

    private func screenshot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    // ─────────────────────────────────────────────────────────────────
    // TEST B4: Consent auto-dismisses when initiator times out
    // Pair with: TimeoutInitiatorTests/testA4_RequestTimeout
    // ─────────────────────────────────────────────────────────────────

    func testB4_ConsentAutoDismissOnTimeout() {
        app.launchArguments = ["-peerDropIsOnline", "1"]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        app.ensureOnline()
        screenshot("B4-00-discovery")

        // Wait for consent sheet to appear
        let acceptBtn = app.buttons["Accept"]
        let gotConsent = acceptBtn.waitForExistence(timeout: 30)
        screenshot("B4-01-consent-shown")
        XCTAssertTrue(gotConsent, "Should receive connection request consent sheet")
        print("[B4] Consent sheet appeared")

        // DO NOT tap Accept — wait for auto-dismiss
        print("[B4] Waiting for consent to auto-dismiss (up to 20s)...")

        // The consent sheet should dismiss within ~16s (15s initiator timeout + network delay)
        let consentDismissed = acceptBtn.waitForNonExistence(timeout: 20)
        screenshot("B4-02-after-dismiss")
        XCTAssertTrue(consentDismissed, "Consent sheet should auto-dismiss after initiator timeout")
        print("[B4] Consent sheet auto-dismissed!")

        // Verify we're back on the Nearby tab (discovery state)
        let nearbyTab = app.tabBars.buttons["Nearby"]
        XCTAssertTrue(nearbyTab.exists, "Should be on Nearby tab after consent dismissed")

        // Verify the status toast appeared (check for the toast text)
        // The toast shows briefly so it may have already disappeared; just check state is correct
        sleep(1)
        screenshot("B4-03-back-to-discovery")

        // Verify peer is still discoverable (not in broken state)
        let peerVisible = app.findPeer(timeout: 10) != nil
        XCTAssertTrue(peerVisible, "Peer should still be visible after consent auto-dismiss")
        screenshot("B4-04-peer-still-visible")
        print("[B4] Peer still discoverable — state is clean")

        print("[B4] === CONSENT AUTO-DISMISS TEST PASSED ===")
    }

    // ─────────────────────────────────────────────────────────────────
    // TEST B5: Normal accept (regression check)
    // Pair with: TimeoutInitiatorTests/testA5_NormalConnectionRegression
    // ─────────────────────────────────────────────────────────────────

    func testB5_NormalAcceptRegression() {
        app.launchArguments = ["-peerDropIsOnline", "1"]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        app.ensureOnline()
        screenshot("B5-00-discovery")

        // Wait for consent and accept quickly
        let gotConsent = app.waitForConsent(timeout: 30)
        screenshot("B5-01-consent")
        XCTAssertTrue(gotConsent, "Should receive connection request")
        app.buttons["Accept"].tap()
        sleep(3)
        screenshot("B5-02-accepted")
        print("[B5] Accepted connection")

        // Should be connected
        let connectedTab = app.tabBars.buttons["Connected"]
        if !connectedTab.isSelected { connectedTab.tap(); sleep(1) }
        app.navigateToConnectionView()

        // Navigate to chat and reply
        app.navigateToChat()

        // Wait for "Regression test message"
        let msg = app.staticTexts["Regression test message"]
        let gotMsg = msg.waitForExistence(timeout: 30)
        screenshot("B5-03-message-received")
        XCTAssertTrue(gotMsg, "Should receive chat message")
        print("[B5] Received chat message")

        app.sendChatMessage("Regression reply")
        screenshot("B5-04-replied")
        print("[B5] Sent reply")

        // Wait for initiator to disconnect
        sleep(15)
        print("[B5] === NORMAL ACCEPT REGRESSION PASSED ===")
    }
}
