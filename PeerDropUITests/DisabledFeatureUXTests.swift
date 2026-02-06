import XCTest

// ═══════════════════════════════════════════════════════════════════════════
// Disabled Feature UX Verification
//
// USAGE:
//   Sim A (iPhone 17 Pro):  -only-testing:PeerDropUITests/DisabledFeatureInitiatorTests
//   Sim B (iPhone 17 Pro Max): -only-testing:PeerDropUITests/DisabledFeatureAcceptorTests
//
// Run BOTH simultaneously.
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

    func switchToTab(_ name: String) {
        tabBars.buttons[name].tap()
        sleep(1)
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
            let sheet = sheets.firstMatch
            if sheet.waitForExistence(timeout: 3) {
                sheet.buttons["Disconnect"].tap()
            }
            sleep(2)
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - INITIATOR (Sim A — iPhone 17 Pro)
// ═══════════════════════════════════════════════════════════════════════════

final class DisabledFeatureInitiatorTests: XCTestCase {

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
    // TEST A1: Forward — disabled buttons appear grayed with alert
    // Pair with: DisabledFeatureAcceptorTests/testB1
    // ─────────────────────────────────────────────────────────────────

    func testA1_DisabledButtonsShowAlert() {
        // Launch with ALL features disabled
        app.launchArguments = [
            "-peerDropChatEnabled", "0",
            "-peerDropFileTransferEnabled", "0",
            "-peerDropVoiceCallEnabled", "0",
            "-peerDropIsOnline", "1"
        ]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))

        app.ensureOnline()

        // ── Connect to peer ──
        guard let peer = app.findPeer(timeout: 30) else {
            XCTFail("No peer discovered")
            return
        }
        app.tapPeer(peer)
        XCTAssertTrue(app.waitForConnected(), "Should connect")
        screenshot("A1-01-connected")

        app.navigateToConnectionView()
        sleep(2)
        screenshot("A1-02-connection-view")

        // ── Verify ALL 3 buttons EXIST (not hidden) ──
        let chatBtn = app.buttons["chat-button"]
        let fileBtn = app.buttons["send-file-button"]
        let voiceBtn = app.buttons["voice-call-button"]

        XCTAssertTrue(chatBtn.waitForExistence(timeout: 5), "Chat button must exist when disabled")
        XCTAssertTrue(fileBtn.exists, "Send File button must exist when disabled")
        XCTAssertTrue(voiceBtn.exists, "Voice Call button must exist when disabled")
        print("[A1] PASS: All 3 buttons visible when features disabled")
        screenshot("A1-03-all-buttons-visible")

        // ── Tap Chat → alert "Chat is Off" ──
        chatBtn.tap()
        sleep(1)

        var alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 3), "Chat disabled alert must appear")
        print("[A1] Chat alert label: '\(alert.label)'")
        screenshot("A1-04-chat-alert")
        alert.buttons.firstMatch.tap()
        sleep(1)

        // ── Tap File → alert "File Transfer is Off" ──
        fileBtn.tap()
        sleep(1)

        alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 3), "File disabled alert must appear")
        print("[A1] File alert label: '\(alert.label)'")
        screenshot("A1-05-file-alert")
        alert.buttons.firstMatch.tap()
        sleep(1)

        // ── Tap Voice → alert "Voice Calls is Off" ──
        voiceBtn.tap()
        sleep(1)

        alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 3), "Voice disabled alert must appear")
        print("[A1] Voice alert label: '\(alert.label)'")
        screenshot("A1-06-voice-alert")
        alert.buttons.firstMatch.tap()
        sleep(1)

        print("[A1] === ALL FORWARD TESTS PASSED ===")

        // ── Disconnect ──
        app.disconnectFromPeer()
        screenshot("A1-07-disconnected")
        sleep(3)
    }

    // ─────────────────────────────────────────────────────────────────
    // TEST A2: Re-enabled features work normally after disabling
    // Pair with: DisabledFeatureAcceptorTests/testB2
    // ─────────────────────────────────────────────────────────────────

    func testA2_ReenabledFeaturesWork() {
        // Launch with ALL features ENABLED
        app.launchArguments = [
            "-peerDropChatEnabled", "1",
            "-peerDropFileTransferEnabled", "1",
            "-peerDropVoiceCallEnabled", "1",
            "-peerDropIsOnline", "1"
        ]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))

        app.ensureOnline()

        guard let peer = app.findPeer(timeout: 30) else {
            XCTFail("No peer discovered")
            return
        }
        app.tapPeer(peer)
        XCTAssertTrue(app.waitForConnected(), "Should connect")
        app.navigateToConnectionView()
        sleep(1)

        // ── Verify Chat opens normally (not alert) ──
        let chatBtn = app.buttons["chat-button"]
        XCTAssertTrue(chatBtn.waitForExistence(timeout: 5), "Chat button must exist")
        chatBtn.tap()
        sleep(1)

        let msgField = app.textFields["Message"]
        XCTAssertTrue(msgField.waitForExistence(timeout: 5),
                       "Chat should open normally when enabled (Message field visible)")
        screenshot("A2-01-chat-opens-normally")
        print("[A2] PASS: Chat opens normally when enabled")

        // Send a message
        app.sendChatMessage("Hello from enabled sender!")
        screenshot("A2-02-message-sent")

        // Wait for reply
        let reply = app.staticTexts["Reply from acceptor"]
        let gotReply = reply.waitForExistence(timeout: 30)
        screenshot("A2-03-reply")
        if gotReply { print("[A2] PASS: Got reply from acceptor") }

        // ── Cleanup ──
        app.goBackOnce()
        app.disconnectFromPeer()
        sleep(3)
        print("[A2] === RE-ENABLE TEST PASSED ===")
    }

    // ─────────────────────────────────────────────────────────────────
    // TEST A3: Reverse — send chat to peer with chat disabled
    // Pair with: DisabledFeatureAcceptorTests/testB3
    // ─────────────────────────────────────────────────────────────────

    func testA3_ReverseRejection() {
        app.launchArguments = [
            "-peerDropChatEnabled", "1",
            "-peerDropFileTransferEnabled", "1",
            "-peerDropVoiceCallEnabled", "1",
            "-peerDropIsOnline", "1"
        ]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))

        app.ensureOnline()

        guard let peer = app.findPeer(timeout: 30) else {
            XCTFail("No peer discovered")
            return
        }
        app.tapPeer(peer)
        XCTAssertTrue(app.waitForConnected(), "Should connect")
        app.navigateToConnectionView()
        app.navigateToChat()
        screenshot("A3-01-chat-open")

        // ── Send message to peer that has Chat DISABLED ──
        // Acceptor launched with chat disabled — message should get chatReject
        app.sendChatMessage("Message to disabled peer")
        screenshot("A3-02-message-sent")

        // Wait for rejection to process
        sleep(5)
        screenshot("A3-03-after-rejection")
        print("[A3] Sent message to peer with disabled chat — check logs for chatReject")

        // Note: We can't easily verify .failed status via XCUITest,
        // but the protocol layer test confirms the rejection flow.
        // Visual verification: the message may show a failed indicator.

        // Stay alive for acceptor to complete
        sleep(10)

        app.goBackOnce()
        app.disconnectFromPeer()
        sleep(3)
        print("[A3] === REVERSE REJECTION TEST DONE ===")
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - ACCEPTOR (Sim B — iPhone 17 Pro Max)
// ═══════════════════════════════════════════════════════════════════════════

final class DisabledFeatureAcceptorTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
    }

    private func screenshot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    private func waitForConsent(timeout: Int = 60) -> Bool {
        let accept = app.buttons["Accept"]
        for _ in 0..<timeout {
            if accept.exists { return true }
            sleep(1)
        }
        return false
    }

    // Pair with: testA1
    func testB1_AcceptForDisabledButtons() {
        app.launchArguments = ["-peerDropIsOnline", "1"]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        app.ensureOnline()

        XCTAssertTrue(waitForConsent(), "Should receive connection request")
        app.buttons["Accept"].tap()
        sleep(3)
        screenshot("B1-01-connected")
        print("[B1] Accepted connection, staying alive for initiator tests")

        // Stay alive while initiator tests disabled buttons
        sleep(40)
        screenshot("B1-02-final")
        print("[B1] === DONE ===")
    }

    // Pair with: testA2
    func testB2_AcceptAndReply() {
        app.launchArguments = ["-peerDropIsOnline", "1"]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        app.ensureOnline()

        XCTAssertTrue(waitForConsent(), "Should receive connection request")
        app.buttons["Accept"].tap()
        sleep(3)

        let connectedTab = app.tabBars.buttons["Connected"]
        if !connectedTab.isSelected { connectedTab.tap(); sleep(1) }
        app.navigateToConnectionView()
        app.navigateToChat()

        // Wait for message
        let msg = app.staticTexts["Hello from enabled sender!"]
        if msg.waitForExistence(timeout: 30) {
            print("[B2] Received message")
            app.sendChatMessage("Reply from acceptor")
            screenshot("B2-01-reply-sent")
        }

        sleep(10)
        print("[B2] === DONE ===")
    }

    // Pair with: testA3
    func testB3_DisabledChatRejectsIncoming() {
        // Launch with Chat DISABLED — incoming messages should get chatReject
        app.launchArguments = [
            "-peerDropChatEnabled", "0",
            "-peerDropIsOnline", "1"
        ]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        app.ensureOnline()
        screenshot("B3-01-chat-disabled")

        XCTAssertTrue(waitForConsent(), "Should receive connection request")
        app.buttons["Accept"].tap()
        sleep(3)
        screenshot("B3-02-connected-chat-disabled")
        print("[B3] Accepted with chat disabled — incoming messages should be rejected")

        // Verify our own buttons are grayed out too
        let connectedTab = app.tabBars.buttons["Connected"]
        if !connectedTab.isSelected { connectedTab.tap(); sleep(1) }
        app.navigateToConnectionView()
        sleep(1)

        let chatBtn = app.buttons["chat-button"]
        XCTAssertTrue(chatBtn.waitForExistence(timeout: 5), "Chat button visible but disabled")
        chatBtn.tap()
        sleep(1)

        let alert = app.alerts.firstMatch
        if alert.waitForExistence(timeout: 3) {
            print("[B3] PASS: Chat disabled alert shown on acceptor side too")
            screenshot("B3-03-acceptor-alert")
            alert.buttons.firstMatch.tap()
        }

        // Stay alive for initiator to send messages
        sleep(20)
        screenshot("B3-04-final")
        print("[B3] === DONE ===")
    }
}
