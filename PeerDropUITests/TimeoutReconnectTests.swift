import XCTest

// ═══════════════════════════════════════════════════════════════════════════
// Timeout & Reconnection Verification
//
// Tests connection reliability after timeouts, disconnects, and reconnects.
//
// USAGE (run pairs simultaneously):
//   Pair 1 (connect → disconnect → reconnect → chat):
//     Sim A:  -only-testing:PeerDropUITests/ReconnectInitiatorTests/testA1_DisconnectAndReconnect
//     Sim B:  -only-testing:PeerDropUITests/ReconnectAcceptorTests/testB1_AcceptDisconnectReaccept
//
//   Pair 2 (remote disconnect → reconnect):
//     Sim A:  -only-testing:PeerDropUITests/ReconnectInitiatorTests/testA2_RemoteDisconnectReconnect
//     Sim B:  -only-testing:PeerDropUITests/ReconnectAcceptorTests/testB2_DisconnectThenReaccept
//
//   Pair 3 (rapid reconnect cycle):
//     Sim A:  -only-testing:PeerDropUITests/ReconnectInitiatorTests/testA3_RapidReconnectCycle
//     Sim B:  -only-testing:PeerDropUITests/ReconnectAcceptorTests/testB3_AcceptRapidReconnects
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

    func waitForDisconnected(timeout: Int = 15) -> Bool {
        // After disconnect we should land on Nearby tab or see Reconnect button
        let nearby = tabBars.buttons["Nearby"]
        let reconnect = buttons["Reconnect"]
        for _ in 0..<timeout {
            if nearby.isSelected || reconnect.exists { return true }
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
        // The ConnectionView has a "Disconnect" button that opens a DisconnectSheet.
        // The sheet also contains a primary action button with id "sheet-primary-action".
        let btn = buttons.matching(identifier: "Disconnect").firstMatch
        if btn.waitForExistence(timeout: 5) {
            btn.tap()
            sleep(1)
            // Tap the sheet's primary action button (Disconnect confirm)
            let sheetBtn = buttons["sheet-primary-action"]
            if sheetBtn.waitForExistence(timeout: 5) {
                sheetBtn.tap()
            }
            sleep(2)
        }
    }

    func tapReconnect() -> Bool {
        let btn = buttons["Reconnect"]
        if btn.waitForExistence(timeout: 10) {
            btn.tap()
            return true
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

    /// Navigate to Nearby tab and find + tap peer to initiate new connection
    func connectToPeer(timeout: TimeInterval = 30) -> Bool {
        let nearbyTab = tabBars.buttons["Nearby"]
        if nearbyTab.exists && !nearbyTab.isSelected {
            nearbyTab.tap()
            sleep(1)
        }
        guard let peer = findPeer(timeout: timeout) else { return false }
        tapPeer(peer)
        return waitForConnected(timeout: 60)
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - INITIATOR (Sim A — iPhone 17 Pro)
// ═══════════════════════════════════════════════════════════════════════════

final class ReconnectInitiatorTests: XCTestCase {

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
    // TEST A1: Connect → Disconnect → Reconnect → Verify Chat Works
    // Pair with: ReconnectAcceptorTests/testB1_AcceptDisconnectReaccept
    // ─────────────────────────────────────────────────────────────────

    func testA1_DisconnectAndReconnect() {
        app.launchArguments = ["-peerDropIsOnline", "1"]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        app.ensureOnline()

        // ── Phase 1: Initial connection ──
        guard let peer = app.findPeer(timeout: 30) else {
            XCTFail("No peer discovered"); return
        }
        app.tapPeer(peer)
        XCTAssertTrue(app.waitForConnected(), "Should connect initially")
        screenshot("A1-01-connected")
        print("[A1] Phase 1: Connected")

        // Send a message to verify connection works
        app.navigateToConnectionView()
        app.navigateToChat()
        app.sendChatMessage("Before disconnect")
        sleep(2)
        screenshot("A1-02-message-sent")

        // ── Phase 2: Disconnect ──
        app.goBackOnce()
        app.disconnectFromPeer()
        screenshot("A1-03-disconnected")
        print("[A1] Phase 2: Disconnected")

        // Wait for state to settle
        sleep(3)

        // ── Phase 3: Reconnect ──
        // After disconnect the app may show terminal state or auto-return to discovery.
        // Try "Back to Discovery" or "Reconnect" if visible, then find peer in Nearby.
        let backBtn = app.buttons["Back to Discovery"]
        let reconnectBtn = app.buttons["Reconnect"]
        if backBtn.waitForExistence(timeout: 5) {
            backBtn.tap()
            sleep(2)
        } else if reconnectBtn.exists {
            reconnectBtn.tap()
            // Reconnect reuses last peer — just wait for connection
            XCTAssertTrue(app.waitForConnected(timeout: 60), "Reconnect button should reconnect")
            screenshot("A1-04-reconnected")
            print("[A1] Phase 3: Reconnected via Reconnect button")
            // Skip peer discovery — already connected
            app.navigateToConnectionView()
            app.navigateToChat()

            let msgField2 = app.textFields["Message"]
            XCTAssertTrue(msgField2.waitForExistence(timeout: 10), "Chat should open after reconnect")
            app.sendChatMessage("After reconnect")
            screenshot("A1-05-chat-after-reconnect")

            let reply2 = app.staticTexts["Reply after reconnect"]
            let gotReply2 = reply2.waitForExistence(timeout: 30)
            screenshot("A1-06-reply-received")
            XCTAssertTrue(gotReply2, "Should receive reply after reconnect")
            print("[A1] Phase 4: Chat works after reconnect")

            app.goBackOnce()
            app.disconnectFromPeer()
            sleep(2)
            print("[A1] === DISCONNECT-RECONNECT TEST PASSED ===")
            return
        }

        // Now on Nearby tab — find peer and reconnect
        let nearbyTab = app.tabBars.buttons["Nearby"]
        if nearbyTab.exists && !nearbyTab.isSelected {
            nearbyTab.tap()
            sleep(1)
        }

        // Bonjour re-advertisement can take time — wait up to 60s
        guard let peer2 = app.findPeer(timeout: 60) else {
            XCTFail("Peer not re-discovered after disconnect")
            return
        }
        app.tapPeer(peer2)
        XCTAssertTrue(app.waitForConnected(timeout: 60), "Should reconnect to peer")
        screenshot("A1-04-reconnected")
        print("[A1] Phase 3: Reconnected")

        // ── Phase 4: Verify chat works after reconnect ──
        app.navigateToConnectionView()
        app.navigateToChat()

        let msgField = app.textFields["Message"]
        XCTAssertTrue(msgField.waitForExistence(timeout: 10), "Chat should open after reconnect")
        app.sendChatMessage("After reconnect")
        screenshot("A1-05-chat-after-reconnect")

        // Wait for reply
        let reply = app.staticTexts["Reply after reconnect"]
        let gotReply = reply.waitForExistence(timeout: 30)
        screenshot("A1-06-reply-received")
        XCTAssertTrue(gotReply, "Should receive reply after reconnect")
        print("[A1] Phase 4: Chat works after reconnect")

        // ── Cleanup ──
        app.goBackOnce()
        app.disconnectFromPeer()
        sleep(2)
        print("[A1] === DISCONNECT-RECONNECT TEST PASSED ===")
    }

    // ─────────────────────────────────────────────────────────────────
    // TEST A2: Remote peer disconnects → Reconnect from failed state
    // Pair with: ReconnectAcceptorTests/testB2_DisconnectThenReaccept
    // ─────────────────────────────────────────────────────────────────

    func testA2_RemoteDisconnectReconnect() {
        app.launchArguments = ["-peerDropIsOnline", "1"]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        app.ensureOnline()

        // ── Phase 1: Connect ──
        guard let peer = app.findPeer(timeout: 30) else {
            XCTFail("No peer discovered"); return
        }
        app.tapPeer(peer)
        XCTAssertTrue(app.waitForConnected(), "Should connect")
        screenshot("A2-01-connected")
        print("[A2] Phase 1: Connected")

        // ── Phase 2: Wait for remote disconnect ──
        // Acceptor (B2) will disconnect after 10 seconds.
        // We should see disconnected/failed state.
        print("[A2] Phase 2: Waiting for remote disconnect...")
        let reconnectBtn = app.buttons["Reconnect"]
        let backToDiscovery = app.buttons["Back to Discovery"]
        var sawDisconnect = false
        for _ in 0..<30 {
            if reconnectBtn.exists || backToDiscovery.exists {
                sawDisconnect = true
                break
            }
            sleep(1)
        }
        screenshot("A2-02-remote-disconnected")
        XCTAssertTrue(sawDisconnect, "Should detect remote disconnect")
        print("[A2] Phase 2: Remote disconnect detected")

        // ── Phase 3: Reconnect ──
        sleep(3) // Let discovery restart

        // Try reconnect button first, otherwise go to discovery
        if reconnectBtn.exists {
            reconnectBtn.tap()
            print("[A2] Tapped Reconnect button")
        } else {
            backToDiscovery.tap()
            sleep(2)
            XCTAssertTrue(app.connectToPeer(timeout: 30), "Should reconnect via discovery")
        }
        XCTAssertTrue(app.waitForConnected(timeout: 60), "Should reconnect after remote disconnect")
        screenshot("A2-03-reconnected")
        print("[A2] Phase 3: Reconnected after remote disconnect")

        // ── Phase 4: Verify chat works ──
        app.navigateToConnectionView()
        app.navigateToChat()
        app.sendChatMessage("Alive after remote disconnect")
        screenshot("A2-04-message-sent")

        let reply = app.staticTexts["Confirmed alive"]
        let gotReply = reply.waitForExistence(timeout: 30)
        screenshot("A2-05-reply")
        XCTAssertTrue(gotReply, "Chat should work after remote disconnect + reconnect")
        print("[A2] Phase 4: Chat verified after remote disconnect + reconnect")

        app.goBackOnce()
        app.disconnectFromPeer()
        sleep(2)
        print("[A2] === REMOTE DISCONNECT-RECONNECT TEST PASSED ===")
    }

    // ─────────────────────────────────────────────────────────────────
    // TEST A3: Rapid connect/disconnect/reconnect cycle (3 rounds)
    // Pair with: ReconnectAcceptorTests/testB3_AcceptRapidReconnects
    // ─────────────────────────────────────────────────────────────────

    func testA3_RapidReconnectCycle() {
        app.launchArguments = ["-peerDropIsOnline", "1"]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        app.ensureOnline()

        for round in 1...3 {
            print("[A3] === Round \(round) ===")

            // Connect
            guard let peer = app.findPeer(timeout: 30) else {
                XCTFail("Round \(round): No peer found"); return
            }
            app.tapPeer(peer)
            XCTAssertTrue(app.waitForConnected(timeout: 30), "Round \(round): Should connect")
            screenshot("A3-\(round)a-connected")
            print("[A3] Round \(round): Connected")

            // Verify connection by navigating to connection view
            app.navigateToConnectionView()
            sleep(1)

            // Send a message to prove connection works
            app.navigateToChat()
            app.sendChatMessage("Round \(round) from initiator")
            sleep(2)
            screenshot("A3-\(round)b-message-sent")

            // Disconnect
            app.goBackOnce()
            app.disconnectFromPeer()
            screenshot("A3-\(round)c-disconnected")
            print("[A3] Round \(round): Disconnected")

            // Navigate back to Nearby tab for next round
            let nearbyTab = app.tabBars.buttons["Nearby"]
            if nearbyTab.exists { nearbyTab.tap() }
            sleep(5)
        }

        print("[A3] === RAPID RECONNECT CYCLE PASSED (3 rounds) ===")
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - ACCEPTOR (Sim B — iPhone 17 Pro Max)
// ═══════════════════════════════════════════════════════════════════════════

final class ReconnectAcceptorTests: XCTestCase {

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
    // B1: Accept → stay alive → accept reconnection → reply
    // Pair with: testA1_DisconnectAndReconnect
    // ─────────────────────────────────────────────────────────────────

    func testB1_AcceptDisconnectReaccept() {
        app.launchArguments = ["-peerDropIsOnline", "1"]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        app.ensureOnline()

        // ── Accept initial connection ──
        XCTAssertTrue(app.waitForConsent(), "Should receive initial connection request")
        app.buttons["Accept"].tap()
        sleep(3)
        screenshot("B1-01-connected")
        print("[B1] Phase 1: Accepted initial connection")

        // ── Wait for disconnect (initiator will disconnect) ──
        print("[B1] Waiting for disconnect...")
        sleep(8)
        screenshot("B1-02-after-disconnect")

        // ── Accept reconnection ──
        let gotReconnect = app.waitForConsent(timeout: 30)
        if gotReconnect {
            app.buttons["Accept"].tap()
            sleep(3)
            screenshot("B1-03-reconnected")
            print("[B1] Phase 2: Accepted reconnection")
        } else {
            print("[B1] No reconnection request received — checking if already connected")
            screenshot("B1-03-no-reconnect-request")
        }

        // ── Navigate to chat and reply ──
        let connectedTab = app.tabBars.buttons["Connected"]
        if !connectedTab.isSelected { connectedTab.tap(); sleep(1) }
        app.navigateToConnectionView()
        app.navigateToChat()

        // Wait for "After reconnect" message
        let msg = app.staticTexts["After reconnect"]
        if msg.waitForExistence(timeout: 30) {
            print("[B1] Received message after reconnect")
            app.sendChatMessage("Reply after reconnect")
            screenshot("B1-04-replied")
        }

        sleep(10)
        print("[B1] === DONE ===")
    }

    // ─────────────────────────────────────────────────────────────────
    // B2: Accept → disconnect from our side → accept reconnection
    // Pair with: testA2_RemoteDisconnectReconnect
    // ─────────────────────────────────────────────────────────────────

    func testB2_DisconnectThenReaccept() {
        app.launchArguments = ["-peerDropIsOnline", "1"]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        app.ensureOnline()

        // ── Accept connection ──
        XCTAssertTrue(app.waitForConsent(), "Should receive connection request")
        app.buttons["Accept"].tap()
        sleep(3)
        screenshot("B2-01-connected")
        print("[B2] Phase 1: Connected")

        // ── Wait a bit then disconnect from OUR side ──
        sleep(5)
        let connectedTab = app.tabBars.buttons["Connected"]
        if !connectedTab.isSelected { connectedTab.tap(); sleep(1) }
        app.navigateToConnectionView()
        app.disconnectFromPeer()
        screenshot("B2-02-we-disconnected")
        print("[B2] Phase 2: We disconnected (remote peer should detect)")

        // ── Accept reconnection from initiator ──
        let gotReconnect = app.waitForConsent(timeout: 45)
        XCTAssertTrue(gotReconnect, "Should receive reconnection request")
        if gotReconnect {
            app.buttons["Accept"].tap()
            sleep(3)
            screenshot("B2-03-reconnected")
            print("[B2] Phase 3: Accepted reconnection")
        }

        // ── Navigate to chat and reply ──
        if !connectedTab.isSelected { connectedTab.tap(); sleep(1) }
        app.navigateToConnectionView()
        app.navigateToChat()

        let msg = app.staticTexts["Alive after remote disconnect"]
        if msg.waitForExistence(timeout: 30) {
            print("[B2] Received message after reconnect")
            app.sendChatMessage("Confirmed alive")
            screenshot("B2-04-replied")
        }

        sleep(10)
        print("[B2] === DONE ===")
    }

    // ─────────────────────────────────────────────────────────────────
    // B3: Accept rapid reconnect cycles (3 rounds)
    // Pair with: testA3_RapidReconnectCycle
    // ─────────────────────────────────────────────────────────────────

    func testB3_AcceptRapidReconnects() {
        app.launchArguments = ["-peerDropIsOnline", "1"]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        app.ensureOnline()

        for round in 1...3 {
            print("[B3] === Round \(round): Waiting for connection ===")

            let gotConsent = app.waitForConsent(timeout: 60)
            if gotConsent {
                app.buttons["Accept"].tap()
                sleep(3)
                screenshot("B3-\(round)a-accepted")
                print("[B3] Round \(round): Accepted")
            } else {
                print("[B3] Round \(round): No consent request received")
                screenshot("B3-\(round)a-no-consent")
                continue
            }

            // Navigate to chat and wait for message
            let connectedTab = app.tabBars.buttons["Connected"]
            if !connectedTab.isSelected { connectedTab.tap(); sleep(1) }
            app.navigateToConnectionView()
            app.navigateToChat()

            let msg = app.staticTexts["Round \(round) from initiator"]
            if msg.waitForExistence(timeout: 15) {
                print("[B3] Round \(round): Received message")
                screenshot("B3-\(round)b-message-received")
            }

            // Wait for initiator to disconnect before next round
            print("[B3] Round \(round): Waiting for disconnect...")
            sleep(15)
            screenshot("B3-\(round)c-after-disconnect")
        }

        print("[B3] === RAPID RECONNECT ACCEPTOR DONE ===")
    }
}
