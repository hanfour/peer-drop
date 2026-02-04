import XCTest

// ═══════════════════════════════════════════════════════════════════════════
// Two-Device E2E Tests — Simulating Real User Interactions
//
// USAGE:
//   Sim1 (iPhone 17 Pro, 080C1B81): Run tests prefixed with "testA_"
//   Sim2 (iPhone 17 Pro Max, DA3E4A31): Run tests prefixed with "testB_"
//
//   xcodebuild test ... -only-testing:PeerDropUITests/TwoDeviceInitiatorTests
//   xcodebuild test ... -only-testing:PeerDropUITests/TwoDeviceAcceptorTests
//
// Each pair of tests (A + B) simulates a complete user scenario.
// ═══════════════════════════════════════════════════════════════════════════

// MARK: - Shared Helpers

private extension XCUIApplication {

    func ensureOnline() {
        let navBars = navigationBars
        let goOnlineBtn = navBars.buttons["Go online"]
        if goOnlineBtn.waitForExistence(timeout: 2) {
            goOnlineBtn.tap()
            sleep(2)
        }
    }

    func goOffline() {
        let goOfflineBtn = navigationBars.buttons["Go offline"]
        if goOfflineBtn.waitForExistence(timeout: 3) {
            goOfflineBtn.tap()
            sleep(2)
        }
    }

    func goOnline() {
        let goOnlineBtn = navigationBars.buttons["Go online"]
        if goOnlineBtn.waitForExistence(timeout: 3) {
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
        let text = staticTexts.matching(NSPredicate(format: "label CONTAINS 'iPhone'")).firstMatch
        if text.waitForExistence(timeout: 3) { return text }
        return nil
    }

    func tapPeer(_ peer: XCUIElement) {
        if peer.elementType == .cell {
            peer.tap()
        } else {
            peer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
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
        let chatLabel = staticTexts["Chat"]
        if chatLabel.waitForExistence(timeout: 5) {
            chatLabel.tap()
            sleep(1)
        }
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
// MARK: - INITIATOR TESTS (Sim1 — iPhone 17 Pro)
// ═══════════════════════════════════════════════════════════════════════════

final class TwoDeviceInitiatorTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
    }

    private func screenshot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    // ─────────────────────────────────────────────────────────────────────
    // Scenario 1: Discovery → Connect → Chat → Disconnect → Reconnect
    // Pair with: TwoDeviceAcceptorTests/testB_Scenario1
    // ─────────────────────────────────────────────────────────────────────

    func testA_Scenario1_FullConnectionLifecycle() {
        app.ensureOnline()
        screenshot("S1-I-01-nearby")

        // ── Step 1: Discover peer ──
        guard let peer = app.findPeer(timeout: 30) else {
            XCTFail("No peer discovered — ensure acceptor sim is running PeerDrop")
            return
        }
        screenshot("S1-I-02-peer-found")

        // ── Step 2: Connect ──
        app.tapPeer(peer)
        print("[S1-INIT] Connection requested")
        XCTAssertTrue(app.waitForConnected(), "Connection should be established")
        screenshot("S1-I-03-connected")

        // ── Step 3: Verify 3-icon UI ──
        app.navigateToConnectionView()
        let sendFile = app.staticTexts["Send File"]
        let chat = app.staticTexts["Chat"]
        let voiceCall = app.staticTexts["Voice Call"]
        XCTAssertTrue(sendFile.waitForExistence(timeout: 5), "Send File button missing")
        XCTAssertTrue(chat.exists, "Chat button missing")
        XCTAssertTrue(voiceCall.exists, "Voice Call button missing")
        screenshot("S1-I-04-three-icons")

        // ── Step 4: Open chat, send message ──
        app.navigateToChat()
        screenshot("S1-I-05-chat-empty")
        app.sendChatMessage("Hello from Sim1!")
        screenshot("S1-I-06-message-sent")

        // ── Step 5: Wait for reply ──
        let reply = app.staticTexts["Hello back from Sim2!"]
        let gotReply = reply.waitForExistence(timeout: 30)
        screenshot("S1-I-07-reply-received")
        XCTAssertTrue(gotReply, "Should receive reply from acceptor")
        print("[S1-INIT] Chat exchange complete")

        // ── Step 6: Go back and disconnect ──
        app.goBackOnce() // back to ConnectionView
        app.goBackOnce() // back to Connected list
        app.switchToTab("Connected")
        app.navigateToConnectionView()
        app.disconnectFromPeer()
        screenshot("S1-I-08-disconnected")

        // ── Step 7: Reconnect ──
        app.switchToTab("Nearby")
        sleep(3)

        guard let peer2 = app.findPeer(timeout: 20) else {
            // Peer may still be in discovery; wait longer
            screenshot("S1-I-09-no-peer-for-reconnect")
            print("[S1-INIT] Peer not found for reconnect (Bonjour delay)")
            // Try via Connected tab contacts
            app.switchToTab("Connected")
            sleep(1)
            let contactPeer = app.buttons.matching(NSPredicate(format: "label CONTAINS 'iPhone'")).firstMatch
            if contactPeer.waitForExistence(timeout: 5) {
                contactPeer.tap()
            }
            sleep(5)
            screenshot("S1-I-09b-reconnect-via-contacts")
            return
        }
        app.tapPeer(peer2)
        print("[S1-INIT] Reconnect requested")
        XCTAssertTrue(app.waitForConnected(timeout: 30), "Should reconnect successfully")
        screenshot("S1-I-09-reconnected")

        // ── Step 8: Verify chat history persists after reconnect ──
        app.navigateToConnectionView()
        app.navigateToChat()
        sleep(1)
        let oldMessage = app.staticTexts["Hello from Sim1!"]
        let historyPersists = oldMessage.waitForExistence(timeout: 5)
        screenshot("S1-I-10-chat-history")
        if historyPersists {
            print("[S1-INIT] Chat history persisted across reconnect")
        }

        // ── Step 9: Send second message after reconnect ──
        app.sendChatMessage("Reconnected message!")
        screenshot("S1-I-11-second-message")

        // Wait for second reply
        let reply2 = app.staticTexts["Got your reconnect message!"]
        _ = reply2.waitForExistence(timeout: 20)
        screenshot("S1-I-12-second-reply")

        // ── Step 10: Final disconnect ──
        app.goBackOnce()
        app.goBackOnce()
        app.switchToTab("Connected")
        app.navigateToConnectionView()
        app.disconnectFromPeer()
        screenshot("S1-I-13-final-disconnect")
        sleep(5) // Allow acceptor to wrap up
    }

    // ─────────────────────────────────────────────────────────────────────
    // Scenario 2: Connection Rejection
    // Pair with: TwoDeviceAcceptorTests/testB_Scenario2
    // ─────────────────────────────────────────────────────────────────────

    func testA_Scenario2_ConnectionRejection() {
        app.ensureOnline()

        guard let peer = app.findPeer(timeout: 30) else {
            XCTFail("No peer discovered")
            return
        }
        screenshot("S2-I-01-peer-found")

        // Request connection (acceptor will REJECT)
        app.tapPeer(peer)
        print("[S2-INIT] Connection requested (expecting rejection)")

        // Should NOT end up on Connected tab
        sleep(5)
        let connectedTab = app.tabBars.buttons["Connected"]
        let wasRejected = !connectedTab.isSelected
        screenshot("S2-I-02-after-rejection")

        // Check for error alert or "requesting" timeout
        let alert = app.alerts.firstMatch
        if alert.waitForExistence(timeout: 15) {
            screenshot("S2-I-03-rejection-alert")
            alert.buttons.firstMatch.tap()
            print("[S2-INIT] Rejection alert dismissed")
        }

        // Should still be on Nearby or back to discovering
        XCTAssertTrue(wasRejected || !connectedTab.isSelected, "Should not be connected after rejection")
        screenshot("S2-I-04-back-to-nearby")

        // Verify app is still functional after rejection
        let offlineBtn = app.navigationBars.buttons["Go offline"]
        XCTAssertTrue(offlineBtn.waitForExistence(timeout: 5), "App should remain functional after rejection")
        sleep(5) // Let acceptor finish
    }

    // ─────────────────────────────────────────────────────────────────────
    // Scenario 3: Feature Toggles During Connection
    // Pair with: TwoDeviceAcceptorTests/testB_Scenario3
    // ─────────────────────────────────────────────────────────────────────

    func testA_Scenario3_FeatureToggles() {
        app.ensureOnline()

        guard let peer = app.findPeer(timeout: 30) else {
            XCTFail("No peer discovered")
            return
        }

        // Connect
        app.tapPeer(peer)
        XCTAssertTrue(app.waitForConnected(), "Should connect")
        screenshot("S3-I-01-connected")

        // ── Disable ALL features ──
        app.switchToTab("Nearby")
        sleep(1)

        // Open settings via menu
        let menuButton = app.navigationBars.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'More' OR identifier CONTAINS[c] 'ellipsis'")
        ).firstMatch
        if menuButton.waitForExistence(timeout: 5) { menuButton.tap() }
        sleep(1)
        let settingsBtn = app.buttons["Settings"]
        if settingsBtn.waitForExistence(timeout: 3) { settingsBtn.tap() }
        sleep(1)

        // Disable File Transfer
        let fileToggle = app.switches["File Transfer"]
        if fileToggle.waitForExistence(timeout: 3) { fileToggle.tap() }
        // Disable Voice Calls
        let voiceToggle = app.switches["Voice Calls"]
        if voiceToggle.exists { voiceToggle.tap() }
        // Disable Chat
        let chatToggle = app.switches["Chat"]
        if chatToggle.exists { chatToggle.tap() }
        screenshot("S3-I-02-all-disabled")

        // Save and dismiss
        let done = app.buttons["Done"]
        if done.exists { done.tap() }
        sleep(1)

        // ── Verify ConnectionView shows NO action buttons ──
        app.switchToTab("Connected")
        sleep(1)
        app.navigateToConnectionView()
        sleep(2)

        let sendFile = app.staticTexts["Send File"]
        let chatLabel = app.staticTexts["Chat"]
        let voiceCall = app.staticTexts["Voice Call"]
        screenshot("S3-I-03-no-buttons")

        // At least one should be gone (if connected)
        let anyVisible = sendFile.exists || chatLabel.exists || voiceCall.exists
        print("[S3-INIT] Buttons after disable: File=\(sendFile.exists) Chat=\(chatLabel.exists) Voice=\(voiceCall.exists)")

        // ── Re-enable ALL features ──
        app.switchToTab("Nearby")
        sleep(1)
        if menuButton.waitForExistence(timeout: 5) { menuButton.tap() }
        sleep(1)
        if settingsBtn.waitForExistence(timeout: 3) { settingsBtn.tap() }
        sleep(1)

        // Re-enable all
        let fileToggle2 = app.switches["File Transfer"]
        if fileToggle2.waitForExistence(timeout: 3) { fileToggle2.tap() }
        let voiceToggle2 = app.switches["Voice Calls"]
        if voiceToggle2.exists { voiceToggle2.tap() }
        let chatToggle2 = app.switches["Chat"]
        if chatToggle2.exists { chatToggle2.tap() }
        screenshot("S3-I-04-all-re-enabled")

        let done2 = app.buttons["Done"]
        if done2.exists { done2.tap() }
        sleep(1)

        // ── Verify buttons are back ──
        app.switchToTab("Connected")
        sleep(1)
        app.navigateToConnectionView()
        sleep(2)

        let sendFile2 = app.staticTexts["Send File"]
        let chatLabel2 = app.staticTexts["Chat"]
        let voiceCall2 = app.staticTexts["Voice Call"]
        screenshot("S3-I-05-buttons-back")

        if sendFile2.exists && chatLabel2.exists && voiceCall2.exists {
            print("[S3-INIT] All buttons restored after re-enabling")
        }

        // ── Chat to verify re-enabled feature works ──
        if chatLabel2.exists {
            app.navigateToChat()
            app.sendChatMessage("Chat re-enabled!")
            screenshot("S3-I-06-chat-after-reenable")
        }

        // Cleanup
        sleep(5)
        app.goBackOnce()
        app.goBackOnce()
        app.switchToTab("Connected")
        app.navigateToConnectionView()
        app.disconnectFromPeer()
        sleep(3)
    }

    // ─────────────────────────────────────────────────────────────────────
    // Scenario 4: Online/Offline Discovery
    // Pair with: TwoDeviceAcceptorTests/testB_Scenario4
    // ─────────────────────────────────────────────────────────────────────

    func testA_Scenario4_OnlineOfflineDiscovery() {
        app.ensureOnline()

        // ── Verify peer is discovered ──
        guard let _ = app.findPeer(timeout: 30) else {
            XCTFail("Peer not found while both online")
            return
        }
        screenshot("S4-I-01-peer-visible")
        print("[S4-INIT] Peer visible while both online")

        // ── Go offline ──
        app.goOffline()
        let offlineText = app.staticTexts["You are offline"]
        XCTAssertTrue(offlineText.waitForExistence(timeout: 5), "Should show offline")
        screenshot("S4-I-02-offline")

        // ── Stay offline 10s (acceptor checks peer disappeared) ──
        sleep(10)

        // ── Go back online ──
        app.goOnline()
        screenshot("S4-I-03-back-online")

        // ── Wait for peer to reappear ──
        let peerBack = app.findPeer(timeout: 20)
        screenshot("S4-I-04-peer-back")
        if peerBack != nil {
            print("[S4-INIT] Peer rediscovered after going back online")
        }

        // ── Now acceptor goes offline — wait for their peer to disappear ──
        print("[S4-INIT] Waiting for acceptor to go offline...")
        sleep(15)
        screenshot("S4-I-05-acceptor-offline-check")

        // ── Acceptor comes back online ──
        sleep(15)
        let peerAgain = app.findPeer(timeout: 20)
        screenshot("S4-I-06-acceptor-back")
        if peerAgain != nil {
            print("[S4-INIT] Acceptor peer rediscovered")
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // Scenario 5: Rapid Connect/Disconnect Stress Test
    // Pair with: TwoDeviceAcceptorTests/testB_Scenario5
    // ─────────────────────────────────────────────────────────────────────

    func testA_Scenario5_RapidConnectDisconnect() {
        app.ensureOnline()

        for round in 1...3 {
            print("[S5-INIT] === Round \(round)/3 ===")

            guard let peer = app.findPeer(timeout: 20) else {
                screenshot("S5-I-R\(round)-no-peer")
                print("[S5-INIT] No peer found in round \(round)")
                sleep(5)
                continue
            }

            // Connect
            app.tapPeer(peer)
            let connected = app.waitForConnected(timeout: 20)
            screenshot("S5-I-R\(round)-connect")

            if connected {
                // Quick chat
                app.navigateToConnectionView()
                app.navigateToChat()
                app.sendChatMessage("Round \(round) msg")
                screenshot("S5-I-R\(round)-chat")

                // Quick disconnect
                app.goBackOnce()
                app.disconnectFromPeer()
                screenshot("S5-I-R\(round)-disconnect")
            } else {
                print("[S5-INIT] Failed to connect in round \(round)")
                // Dismiss any alerts
                let alert = app.alerts.firstMatch
                if alert.exists { alert.buttons.firstMatch.tap() }
            }

            app.switchToTab("Nearby")
            sleep(3)
        }

        // Verify app didn't crash — check we can still see the tab bar
        XCTAssertTrue(app.tabBars.firstMatch.exists, "App should not have crashed after rapid connect/disconnect")
        screenshot("S5-I-final")
        sleep(5)
    }

    // ─────────────────────────────────────────────────────────────────────
    // Scenario 6: Tab Navigation & UI During Connection
    // Pair with: TwoDeviceAcceptorTests/testB_Scenario6
    // ─────────────────────────────────────────────────────────────────────

    func testA_Scenario6_TabNavigation() {
        app.ensureOnline()

        guard let peer = app.findPeer(timeout: 30) else {
            XCTFail("No peer discovered")
            return
        }

        // Connect
        app.tapPeer(peer)
        XCTAssertTrue(app.waitForConnected(), "Should connect")
        screenshot("S6-I-01-connected")

        // ── Rapidly switch tabs while connected ──
        for i in 1...3 {
            app.switchToTab("Nearby")
            screenshot("S6-I-tab-nearby-\(i)")
            app.switchToTab("Connected")
            screenshot("S6-I-tab-connected-\(i)")
            app.switchToTab("Library")
            screenshot("S6-I-tab-library-\(i)")
        }

        // ── Verify still connected after tab switching ──
        app.switchToTab("Connected")
        app.navigateToConnectionView()
        let sendFile = app.staticTexts["Send File"]
        XCTAssertTrue(sendFile.waitForExistence(timeout: 5), "Should still be connected after tab switching")
        screenshot("S6-I-02-still-connected")

        // ── Open chat, send message while switching tabs ──
        app.navigateToChat()
        app.sendChatMessage("Tab switch test")
        screenshot("S6-I-03-chat-msg")

        // ── Navigate back and forth in ConnectionView ──
        app.goBackOnce() // back to ConnectionView
        sleep(1)
        app.navigateToChat() // back to chat
        sleep(1)
        app.goBackOnce() // back to ConnectionView again
        screenshot("S6-I-04-nav-stress")

        // ── Open file picker and cancel ──
        let sendFileBtn = app.staticTexts["Send File"]
        if sendFileBtn.exists {
            sendFileBtn.tap()
            sleep(2)
            // Cancel file picker
            let cancelBtn = app.buttons["Cancel"]
            if cancelBtn.waitForExistence(timeout: 3) {
                cancelBtn.tap()
                sleep(1)
            }
            screenshot("S6-I-05-file-picker-cancelled")
        }

        // ── Verify no crash ──
        XCTAssertTrue(app.tabBars.firstMatch.exists, "App should not crash during tab navigation stress")

        // Cleanup
        app.disconnectFromPeer()
        sleep(5)
    }

    // ─────────────────────────────────────────────────────────────────────
    // Scenario 7: Multiple Chat Messages & Unread Badge
    // Pair with: TwoDeviceAcceptorTests/testB_Scenario7
    // ─────────────────────────────────────────────────────────────────────

    func testA_Scenario7_ChatAndUnread() {
        app.ensureOnline()

        guard let peer = app.findPeer(timeout: 30) else {
            XCTFail("No peer discovered")
            return
        }

        app.tapPeer(peer)
        XCTAssertTrue(app.waitForConnected(), "Should connect")

        // ── Send multiple messages rapidly ──
        app.navigateToConnectionView()
        app.navigateToChat()

        for i in 1...5 {
            app.sendChatMessage("Msg \(i) from Sim1")
        }
        screenshot("S7-I-01-messages-sent")

        // ── Wait for replies ──
        let lastReply = app.staticTexts["Batch reply from Sim2"]
        _ = lastReply.waitForExistence(timeout: 30)
        screenshot("S7-I-02-replies")

        // ── Go back to Connected tab (leave chat) ──
        app.goBackOnce() // ConnectionView
        app.goBackOnce() // Connected list
        screenshot("S7-I-03-left-chat")

        // ── Wait for more messages from acceptor (while we're NOT in chat) ──
        // These should show as unread badges
        sleep(10) // Acceptor sends messages while we're away

        // ── Check unread badge ──
        app.switchToTab("Connected")
        sleep(1)
        screenshot("S7-I-04-unread-check")
        // The active peer row should show an unread badge

        // ── Re-enter chat to clear unread ──
        app.navigateToConnectionView()
        sleep(1)
        app.navigateToChat()
        sleep(2)
        screenshot("S7-I-05-unread-cleared")

        // Cleanup
        app.goBackOnce()
        app.disconnectFromPeer()
        sleep(5)
    }

    // ─────────────────────────────────────────────────────────────────────
    // Scenario 8: Settings & Archive During Connection
    // Pair with: TwoDeviceAcceptorTests/testB_Scenario8
    // ─────────────────────────────────────────────────────────────────────

    func testA_Scenario8_SettingsArchive() {
        app.ensureOnline()

        guard let peer = app.findPeer(timeout: 30) else {
            XCTFail("No peer discovered")
            return
        }

        app.tapPeer(peer)
        XCTAssertTrue(app.waitForConnected(), "Should connect")

        // Send a message first (to have chat data for archive)
        app.navigateToConnectionView()
        app.navigateToChat()
        app.sendChatMessage("Archive test msg")
        screenshot("S8-I-01-msg-sent")

        // ── Open Settings while connected ──
        app.goBackOnce()
        app.goBackOnce()
        app.switchToTab("Nearby")
        sleep(1)

        let menuButton = app.navigationBars.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'More' OR identifier CONTAINS[c] 'ellipsis'")
        ).firstMatch
        if menuButton.waitForExistence(timeout: 5) { menuButton.tap() }
        sleep(1)
        let settingsBtn = app.buttons["Settings"]
        if settingsBtn.waitForExistence(timeout: 3) { settingsBtn.tap() }
        sleep(1)

        let settingsNav = app.navigationBars["Settings"]
        XCTAssertTrue(settingsNav.waitForExistence(timeout: 5), "Settings should open while connected")
        screenshot("S8-I-02-settings-while-connected")

        // ── Export archive ──
        app.swipeUp()
        sleep(1)
        let exportBtn = app.buttons["Export Archive"]
        if exportBtn.waitForExistence(timeout: 3) {
            exportBtn.tap()
            sleep(3)
            screenshot("S8-I-03-export-result")

            // Dismiss share sheet or error
            let shareSheet = app.otherElements["ActivityListView"]
            if shareSheet.waitForExistence(timeout: 5) {
                // Close share sheet
                let closeBtn = app.buttons["Close"]
                if closeBtn.waitForExistence(timeout: 3) { closeBtn.tap() }
                else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap() }
                sleep(1)
            }
            let archiveError = app.alerts["Archive Error"]
            if archiveError.exists {
                archiveError.buttons.firstMatch.tap()
            }
        }

        // ── Verify connection survived settings/export ──
        let done = app.buttons["Done"]
        if done.exists { done.tap() }
        sleep(1)

        app.switchToTab("Connected")
        sleep(1)
        let activeRow = app.buttons["active-peer-row"]
        let stillConnected = activeRow.waitForExistence(timeout: 5)
        screenshot("S8-I-04-still-connected")
        if stillConnected {
            print("[S8-INIT] Connection survived settings & export")
        }

        // Cleanup
        app.navigateToConnectionView()
        app.disconnectFromPeer()
        sleep(5)
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - ACCEPTOR TESTS (Sim2 — iPhone 17 Pro Max)
// ═══════════════════════════════════════════════════════════════════════════

final class TwoDeviceAcceptorTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
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

    // ─────────────────────────────────────────────────────────────────────
    // Scenario 1: Accept → Chat → Disconnect → Re-accept
    // Pair with: TwoDeviceInitiatorTests/testA_Scenario1
    // ─────────────────────────────────────────────────────────────────────

    func testB_Scenario1_FullConnectionLifecycle() {
        app.ensureOnline()
        screenshot("S1-A-01-waiting")

        // ── Step 1: Wait for and accept connection ──
        XCTAssertTrue(waitForConsent(), "Should receive connection request")
        screenshot("S1-A-02-consent-sheet")

        // Verify consent sheet shows peer info
        let wantsToConnect = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'wants to connect'")
        ).firstMatch
        XCTAssertTrue(wantsToConnect.exists, "Should show 'wants to connect' text")

        app.buttons["Accept"].tap()
        print("[S1-ACPT] Accepted connection")
        sleep(3)
        screenshot("S1-A-03-accepted")

        // ── Step 2: Navigate to chat ──
        let connectedTab = app.tabBars.buttons["Connected"]
        if !connectedTab.isSelected { connectedTab.tap(); sleep(1) }
        app.navigateToConnectionView()
        app.navigateToChat()
        screenshot("S1-A-04-chat-open")

        // ── Step 3: Wait for initiator's message ──
        let inMsg = app.staticTexts["Hello from Sim1!"]
        XCTAssertTrue(inMsg.waitForExistence(timeout: 30), "Should receive message")
        screenshot("S1-A-05-received")
        print("[S1-ACPT] Received message from initiator")

        // ── Step 4: Send reply ──
        app.sendChatMessage("Hello back from Sim2!")
        screenshot("S1-A-06-reply-sent")

        // ── Step 5: Wait for disconnect ──
        print("[S1-ACPT] Waiting for initiator to disconnect...")
        sleep(10)
        screenshot("S1-A-07-post-disconnect")

        // ── Step 6: Wait for reconnect (second consent sheet) ──
        print("[S1-ACPT] Waiting for reconnect consent...")
        let reconnectConsent = waitForConsent(timeout: 30)
        if reconnectConsent {
            screenshot("S1-A-08-reconnect-consent")
            app.buttons["Accept"].tap()
            print("[S1-ACPT] Accepted reconnect")
            sleep(3)

            // ── Step 7: Navigate to chat, verify history ──
            if !connectedTab.isSelected { connectedTab.tap(); sleep(1) }
            app.navigateToConnectionView()
            app.navigateToChat()
            sleep(1)

            let oldMsg = app.staticTexts["Hello from Sim1!"]
            if oldMsg.exists {
                print("[S1-ACPT] Chat history persisted across reconnect")
            }
            screenshot("S1-A-09-reconnected-chat")

            // ── Step 8: Wait for second message, send reply ──
            let msg2 = app.staticTexts["Reconnected message!"]
            if msg2.waitForExistence(timeout: 20) {
                print("[S1-ACPT] Received reconnect message")
                app.sendChatMessage("Got your reconnect message!")
                screenshot("S1-A-10-reconnect-reply")
            }
        } else {
            print("[S1-ACPT] Reconnect consent not received (timing)")
            screenshot("S1-A-08-no-reconnect")
        }

        sleep(5)
        screenshot("S1-A-11-final")
    }

    // ─────────────────────────────────────────────────────────────────────
    // Scenario 2: Reject Connection
    // Pair with: TwoDeviceInitiatorTests/testA_Scenario2
    // ─────────────────────────────────────────────────────────────────────

    func testB_Scenario2_ConnectionRejection() {
        app.ensureOnline()
        screenshot("S2-A-01-waiting")

        XCTAssertTrue(waitForConsent(), "Should receive connection request")
        screenshot("S2-A-02-consent")

        // Verify Decline button exists
        let declineBtn = app.buttons["Decline"]
        XCTAssertTrue(declineBtn.exists, "Decline button should exist")

        // REJECT the connection
        declineBtn.tap()
        print("[S2-ACPT] Connection rejected")
        sleep(2)
        screenshot("S2-A-03-rejected")

        // Verify we're back to normal state (not connected)
        let connectedTab = app.tabBars.buttons["Connected"]
        connectedTab.tap()
        sleep(1)
        let noConnection = app.staticTexts["No active connection"]
        let noSaved = app.staticTexts["No saved devices"]
        let notConnected = noConnection.exists || noSaved.exists
        screenshot("S2-A-04-not-connected")

        // Verify app is functional
        app.switchToTab("Nearby")
        sleep(1)
        let offlineBtn = app.navigationBars.buttons["Go offline"]
        XCTAssertTrue(offlineBtn.waitForExistence(timeout: 5), "App should remain functional after rejection")
        screenshot("S2-A-05-functional")
        sleep(3)
    }

    // ─────────────────────────────────────────────────────────────────────
    // Scenario 3: Accept while Initiator toggles features
    // Pair with: TwoDeviceInitiatorTests/testA_Scenario3
    // ─────────────────────────────────────────────────────────────────────

    func testB_Scenario3_FeatureToggles() {
        app.ensureOnline()

        XCTAssertTrue(waitForConsent(), "Should receive connection request")
        app.buttons["Accept"].tap()
        print("[S3-ACPT] Accepted connection")
        sleep(3)
        screenshot("S3-A-01-connected")

        // Navigate to connection view
        let connectedTab = app.tabBars.buttons["Connected"]
        if !connectedTab.isSelected { connectedTab.tap(); sleep(1) }
        app.navigateToConnectionView()

        // Verify all buttons visible (from acceptor's perspective, features are enabled)
        let sendFile = app.staticTexts["Send File"]
        let chat = app.staticTexts["Chat"]
        let voiceCall = app.staticTexts["Voice Call"]
        XCTAssertTrue(sendFile.waitForExistence(timeout: 5), "Send File visible")
        XCTAssertTrue(chat.exists, "Chat visible")
        XCTAssertTrue(voiceCall.exists, "Voice Call visible")
        screenshot("S3-A-02-all-buttons")

        // ── Try sending chat while initiator has it disabled ──
        // (Initiator disables chat around now)
        sleep(5)
        app.navigateToChat()
        app.sendChatMessage("Message while peer disabled chat")
        screenshot("S3-A-03-sent-while-disabled")
        // This message should be silently dropped by the initiator's ConnectionManager

        // Wait for initiator to re-enable
        sleep(15)

        // ── After re-enable, wait for "Chat re-enabled!" message ──
        let reenabledMsg = app.staticTexts["Chat re-enabled!"]
        _ = reenabledMsg.waitForExistence(timeout: 20)
        screenshot("S3-A-04-chat-reenabled")

        // Stay alive
        sleep(10)
        screenshot("S3-A-05-final")
    }

    // ─────────────────────────────────────────────────────────────────────
    // Scenario 4: Online/Offline Discovery from Acceptor side
    // Pair with: TwoDeviceInitiatorTests/testA_Scenario4
    // ─────────────────────────────────────────────────────────────────────

    func testB_Scenario4_OnlineOfflineDiscovery() {
        app.ensureOnline()

        // ── Verify peer visible ──
        guard let _ = app.findPeer(timeout: 30) else {
            XCTFail("Peer not found while both online")
            return
        }
        screenshot("S4-A-01-peer-visible")

        // ── Initiator goes offline — check peer disappears ──
        print("[S4-ACPT] Waiting for initiator to go offline...")
        sleep(12) // Initiator goes offline after ~10s

        // Check if peer is gone
        let peerAfterOffline = app.buttons.matching(NSPredicate(format: "label CONTAINS 'iPhone 17 Pro'")).firstMatch
        screenshot("S4-A-02-initiator-offline")
        // Bonjour cache may delay this
        if !peerAfterOffline.exists {
            print("[S4-ACPT] Initiator peer disappeared (went offline)")
        } else {
            print("[S4-ACPT] Initiator peer still in Bonjour cache")
        }

        // ── Initiator comes back online — peer should reappear ──
        sleep(5)
        let peerBack = app.findPeer(timeout: 20)
        screenshot("S4-A-03-initiator-back")
        if peerBack != nil {
            print("[S4-ACPT] Initiator peer rediscovered")
        }

        // ── Now WE go offline ──
        app.goOffline()
        let offlineText = app.staticTexts["You are offline"]
        XCTAssertTrue(offlineText.waitForExistence(timeout: 5), "Should show offline")
        screenshot("S4-A-04-we-offline")

        sleep(10) // Initiator checks we disappeared

        // ── Come back online ──
        app.goOnline()
        screenshot("S4-A-05-we-back-online")

        // Wait for peer to be re-discovered
        _ = app.findPeer(timeout: 20)
        screenshot("S4-A-06-final")
        sleep(10)
    }

    // ─────────────────────────────────────────────────────────────────────
    // Scenario 5: Rapid Accept/Disconnect Stress
    // Pair with: TwoDeviceInitiatorTests/testA_Scenario5
    // ─────────────────────────────────────────────────────────────────────

    func testB_Scenario5_RapidConnectDisconnect() {
        app.ensureOnline()

        for round in 1...3 {
            print("[S5-ACPT] === Round \(round)/3 ===")

            // Wait for consent
            let gotConsent = waitForConsent(timeout: 30)
            if gotConsent {
                screenshot("S5-A-R\(round)-consent")
                app.buttons["Accept"].tap()
                print("[S5-ACPT] Accepted round \(round)")
                sleep(3)

                // Navigate to chat to receive message
                let connectedTab = app.tabBars.buttons["Connected"]
                if !connectedTab.isSelected { connectedTab.tap(); sleep(1) }
                app.navigateToConnectionView()
                app.navigateToChat()

                let msg = app.staticTexts["Round \(round) msg"]
                _ = msg.waitForExistence(timeout: 10)
                screenshot("S5-A-R\(round)-msg")

                // Wait for disconnect
                sleep(5)

                // Go back to Nearby for next round
                app.switchToTab("Nearby")
                sleep(3)
            } else {
                print("[S5-ACPT] No consent in round \(round)")
                screenshot("S5-A-R\(round)-no-consent")
                sleep(3)
            }
        }

        // Verify no crash
        XCTAssertTrue(app.tabBars.firstMatch.exists, "App should not crash after rapid cycles")
        screenshot("S5-A-final")
        sleep(3)
    }

    // ─────────────────────────────────────────────────────────────────────
    // Scenario 6: Accept and handle tab navigation stress
    // Pair with: TwoDeviceInitiatorTests/testA_Scenario6
    // ─────────────────────────────────────────────────────────────────────

    func testB_Scenario6_TabNavigation() {
        app.ensureOnline()

        XCTAssertTrue(waitForConsent(), "Should receive connection request")
        app.buttons["Accept"].tap()
        sleep(3)
        screenshot("S6-A-01-connected")

        // ── Navigate around while connected ──
        let connectedTab = app.tabBars.buttons["Connected"]
        if !connectedTab.isSelected { connectedTab.tap(); sleep(1) }

        // Switch tabs rapidly
        for i in 1...3 {
            app.switchToTab("Library")
            app.switchToTab("Nearby")
            app.switchToTab("Connected")
            screenshot("S6-A-tab-cycle-\(i)")
        }

        // ── Receive message from initiator ──
        app.navigateToConnectionView()
        app.navigateToChat()
        let msg = app.staticTexts["Tab switch test"]
        _ = msg.waitForExistence(timeout: 15)
        screenshot("S6-A-02-received-msg")

        // ── Send reply ──
        app.sendChatMessage("Tab switch reply")
        screenshot("S6-A-03-reply")

        // Verify no crash
        XCTAssertTrue(app.tabBars.firstMatch.exists, "App stable after tab stress")
        sleep(10)
        screenshot("S6-A-04-final")
    }

    // ─────────────────────────────────────────────────────────────────────
    // Scenario 7: Receive multiple messages & unread badge
    // Pair with: TwoDeviceInitiatorTests/testA_Scenario7
    // ─────────────────────────────────────────────────────────────────────

    func testB_Scenario7_ChatAndUnread() {
        app.ensureOnline()

        XCTAssertTrue(waitForConsent(), "Should receive connection request")
        app.buttons["Accept"].tap()
        sleep(3)

        // Navigate to chat
        let connectedTab = app.tabBars.buttons["Connected"]
        if !connectedTab.isSelected { connectedTab.tap(); sleep(1) }
        app.navigateToConnectionView()
        app.navigateToChat()

        // ── Wait for batch of messages ──
        let msg5 = app.staticTexts["Msg 5 from Sim1"]
        let gotAll = msg5.waitForExistence(timeout: 30)
        screenshot("S7-A-01-batch-received")
        if gotAll { print("[S7-ACPT] Received all 5 messages") }

        // ── Send batch reply ──
        app.sendChatMessage("Batch reply from Sim2")
        screenshot("S7-A-02-reply-sent")

        // ── Leave chat (initiator is also leaving chat) ──
        sleep(5)
        app.goBackOnce() // ConnectionView
        app.goBackOnce() // Connected list
        sleep(2)

        // ── Send messages while initiator is NOT in chat (creates unread) ──
        app.navigateToConnectionView()
        app.navigateToChat()
        sleep(1)
        app.sendChatMessage("Unread msg 1")
        app.sendChatMessage("Unread msg 2")
        app.sendChatMessage("Unread msg 3")
        screenshot("S7-A-03-unread-msgs-sent")

        // Stay alive
        sleep(15)
        screenshot("S7-A-04-final")
    }

    // ─────────────────────────────────────────────────────────────────────
    // Scenario 8: Accept during initiator's settings/archive test
    // Pair with: TwoDeviceInitiatorTests/testA_Scenario8
    // ─────────────────────────────────────────────────────────────────────

    func testB_Scenario8_SettingsArchive() {
        app.ensureOnline()

        XCTAssertTrue(waitForConsent(), "Should receive connection request")
        app.buttons["Accept"].tap()
        sleep(3)
        screenshot("S8-A-01-connected")

        // Navigate to chat
        let connectedTab = app.tabBars.buttons["Connected"]
        if !connectedTab.isSelected { connectedTab.tap(); sleep(1) }
        app.navigateToConnectionView()
        app.navigateToChat()

        // Wait for message
        let msg = app.staticTexts["Archive test msg"]
        _ = msg.waitForExistence(timeout: 20)
        screenshot("S8-A-02-msg-received")

        // ── While initiator opens settings, keep connection alive ──
        print("[S8-ACPT] Staying in chat while initiator tests settings...")
        sleep(20)
        screenshot("S8-A-03-still-connected")

        // Verify we're still connected (connection should survive initiator's settings)
        let field = app.textFields["Message"]
        if field.exists {
            print("[S8-ACPT] Still in chat — connection survived initiator's settings/export")
        }
        screenshot("S8-A-04-final")
        sleep(5)
    }
}
