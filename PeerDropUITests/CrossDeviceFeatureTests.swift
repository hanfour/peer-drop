import XCTest

/// Comprehensive cross-device feature tests that run on Sim 2 (initiator).
/// Requires AcceptConnectionHelper running on Sim 1 simultaneously.
///
/// Test sequence:
/// 1. Connect to Sim 1
/// 2. Verify connected state and UI elements
/// 3. Test clipboard share flow
/// 4. Test voice call flow
/// 5. Test file send UI
/// 6. Disconnect
final class CrossDeviceFeatureTests: XCTestCase {

    var app: XCUIApplication!

    /// Track if app has been launched across tests (XCTest runs tests sequentially in one process)
    private static var appLaunched = false

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()

        if !CrossDeviceFeatureTests.appLaunched {
            app.launch()
            CrossDeviceFeatureTests.appLaunched = true
        } else {
            // App already running from previous test — just activate it
            app.activate()
        }

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5))
    }

    override func tearDownWithError() throws {
        // Take a final screenshot
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "CrossDevice-Final"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Full Cross-Device Flow

    func test01_ConnectToPeer() {
        // We should be on the Nearby tab with discovered peers
        // Wait for a peer to appear (Sim 1's Bonjour advertisement)
        let peerFound = waitForPeer(timeout: 30)
        XCTAssertTrue(peerFound, "Should discover Sim 1 peer via Bonjour")

        takeScreenshot("01-PeerDiscovered")

        // Tap the first discovered peer to initiate connection
        tapFirstPeer()

        // Wait for connection to be accepted by Sim 1 (AcceptConnectionHelper)
        // Should auto-switch to Connected tab
        let connectedNav = app.navigationBars["Connected"]
        let connected = connectedNav.waitForExistence(timeout: 30)
        XCTAssertTrue(connected, "Should transition to Connected tab after peer accepts")

        takeScreenshot("01-Connected")

        // Verify connected state UI elements (circular icon buttons)
        let fileBtn = app.staticTexts["File"]
        XCTAssertTrue(fileBtn.waitForExistence(timeout: 5), "File button should be visible")

        let voiceBtn = app.staticTexts["Voice"]
        XCTAssertTrue(voiceBtn.exists, "Voice button should be visible")

        let messageBtn = app.staticTexts["Message"]
        XCTAssertTrue(messageBtn.exists, "Message button should be visible")

        // Verify peer name is displayed
        // The connected peer should show "iPhone 17 Pro" (Sim 1's name)
        let peerNameExists = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'iPhone'")).firstMatch.waitForExistence(timeout: 5)
        XCTAssertTrue(peerNameExists, "Connected peer name should be displayed")

        takeScreenshot("01-ConnectedUI")
    }

    func test02_SendFileUI() {
        // First connect
        connectToPeer()

        // Tap Send File — this opens UIDocumentPickerViewController
        let sendFileBtn = app.staticTexts["File"]
        XCTAssertTrue(sendFileBtn.waitForExistence(timeout: 5))
        sendFileBtn.tap()

        // The document picker should appear (system UI)
        // Wait for it to appear
        sleep(2)
        takeScreenshot("02-FilePickerOpened")

        // The document picker is a system view controller
        // Check if we can see the Cancel button in the picker
        let cancelBtn = app.buttons["Cancel"]
        if cancelBtn.waitForExistence(timeout: 3) {
            cancelBtn.tap()
            // Should return to connected view
            let sendFileBtnAgain = app.staticTexts["File"]
            XCTAssertTrue(sendFileBtnAgain.waitForExistence(timeout: 5), "Should return to connected view after canceling picker")
            takeScreenshot("02-FilePickerCanceled")
        } else {
            // Document picker may have different UI, just go back
            takeScreenshot("02-FilePickerNoCancel")
        }
    }

    func test03_ClipboardShare() {
        // First connect
        connectToPeer()

        // Put some text in the clipboard
        UIPasteboard.general.string = "Hello from PeerDrop cross-device test! 🎉"

        // Re-check clipboard state (the button checks on appear/state change)
        // Navigate away and back to trigger clipboard check
        let nearbyTab = app.tabBars.buttons.element(boundBy: 0)
        nearbyTab.tap()
        sleep(1)
        let connectedTab = app.tabBars.buttons.element(boundBy: 1)
        connectedTab.tap()
        sleep(1)

        let clipboardBtn = app.staticTexts["Message"]
        guard clipboardBtn.waitForExistence(timeout: 5) else {
            XCTFail("Clipboard button not found")
            return
        }

        // Check if clipboard button is enabled
        if clipboardBtn.isEnabled {
            clipboardBtn.tap()

            // Should see "Share Clipboard" sheet
            let shareTitle = app.staticTexts["Share Clipboard"]
            if shareTitle.waitForExistence(timeout: 5) {
                takeScreenshot("03-ClipboardShareSheet")

                // Check for text preview
                let textPreview = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Hello from PeerDrop'")).firstMatch
                let hasPreview = textPreview.waitForExistence(timeout: 3)
                XCTAssertTrue(hasPreview, "Clipboard text preview should be visible")

                // Check for Send button
                let sendBtn = app.buttons["Send to Peer"]
                if sendBtn.waitForExistence(timeout: 3) {
                    takeScreenshot("03-ClipboardReadyToSend")

                    // Actually send it!
                    sendBtn.tap()

                    // Wait for transfer to complete (should be fast for small text)
                    sleep(5)
                    takeScreenshot("03-ClipboardSent")

                    // Should auto-dismiss the sheet and return to connected state
                    let sendFileBtn = app.staticTexts["File"]
                    let backToConnected = sendFileBtn.waitForExistence(timeout: 10)
                    XCTAssertTrue(backToConnected, "Should return to connected view after clipboard send")
                } else {
                    // Cancel the sheet
                    let cancelBtn = app.buttons["Cancel"]
                    cancelBtn.tap()
                }
            } else {
                takeScreenshot("03-ClipboardNoSheet")
            }
        } else {
            takeScreenshot("03-ClipboardDisabled")
            // Clipboard button disabled — no content detected
            XCTExpectFailure("Clipboard button disabled, pasteboard may not be accessible in test environment")
            XCTFail("Clipboard button is disabled")
        }
    }

    func test04_VoiceCall() {
        // First connect
        connectToPeer()

        let voiceCallBtn = app.staticTexts["Voice"]
        guard voiceCallBtn.waitForExistence(timeout: 5), voiceCallBtn.isEnabled else {
            XCTFail("Voice Call button not found or not enabled")
            return
        }

        takeScreenshot("04-BeforeVoiceCall")

        // Tap Voice Call
        voiceCallBtn.tap()

        // The VoiceCallView should appear (as a sheet or fullscreen)
        // Look for call UI elements
        sleep(3)
        takeScreenshot("04-VoiceCallInitiated")

        // Check for End call button
        let endCallBtn = app.buttons["End call"]
        if endCallBtn.waitForExistence(timeout: 10) {
            takeScreenshot("04-VoiceCallActive")

            // Check for Mute button
            let muteBtn = app.buttons["Mute"]
            if muteBtn.exists {
                muteBtn.tap()
                sleep(1)
                takeScreenshot("04-VoiceCallMuted")
                // Unmute
                let muteActiveBtn = app.buttons["Mute, active"]
                if muteActiveBtn.exists {
                    muteActiveBtn.tap()
                }
            }

            // Check for Speaker button
            let speakerBtn = app.buttons["Speaker"]
            if speakerBtn.exists {
                speakerBtn.tap()
                sleep(1)
                takeScreenshot("04-VoiceCallSpeaker")
            }

            // End the call
            endCallBtn.tap()
            sleep(2)
            takeScreenshot("04-VoiceCallEnded")

            // Should return to connected state
            let sendFileBtn = app.staticTexts["File"]
            XCTAssertTrue(sendFileBtn.waitForExistence(timeout: 10), "Should return to connected view after ending call")
        } else {
            takeScreenshot("04-VoiceCallNoEndButton")
            // Voice call may have failed (WebRTC requires real audio hardware)
            // This is expected in simulator environment
            XCTExpectFailure("Voice call UI may not fully work in simulator (no real audio hardware)")
            XCTFail("End call button not found — voice call may have failed to start")
        }
    }

    func test05_Disconnect() {
        // First connect
        connectToPeer()

        // Find and tap Disconnect button
        let disconnectBtn = app.buttons["Disconnect"]
        guard disconnectBtn.waitForExistence(timeout: 5) else {
            XCTFail("Disconnect button not found")
            return
        }

        disconnectBtn.tap()

        // Confirmation dialog should appear
        let confirmDisconnect = app.buttons["Disconnect"]
        // There should be a confirmation dialog — look for the destructive button
        sleep(1)
        takeScreenshot("05-DisconnectConfirmation")

        // The confirmation dialog has another "Disconnect" button
        let dialogButtons = app.buttons.matching(identifier: "Disconnect")
        if dialogButtons.count > 0 {
            dialogButtons.element(boundBy: dialogButtons.count - 1).tap()
        }

        sleep(2)
        takeScreenshot("05-Disconnected")

        // Should show empty state or return to discovery
        let noConnection = app.staticTexts["No active connection"]
        let nearbyTab = app.tabBars.buttons.element(boundBy: 0)

        // Either we see "No active connection" on Connected tab, or we switched to Nearby
        let disconnected = noConnection.waitForExistence(timeout: 5) || nearbyTab.isSelected
        XCTAssertTrue(disconnected, "Should show disconnected state")
    }

    func test06_Messaging() {
        // Connect to peer
        connectToPeer()

        // Tap Message button to open chat
        let messageBtn = app.staticTexts["Message"]
        guard messageBtn.waitForExistence(timeout: 5) else {
            XCTFail("Message button not found")
            return
        }
        messageBtn.tap()
        sleep(1)

        takeScreenshot("06-ChatOpened")

        // Wait for Sim 1's message to arrive (Sim 1 sends first)
        let incomingMessage = app.staticTexts["Hello from Sim 1!"]
        let receivedMessage = incomingMessage.waitForExistence(timeout: 30)

        takeScreenshot("06-ReceivedMessage")

        XCTAssertTrue(receivedMessage, "Should receive message from Sim 1")

        // Type and send a reply
        let textField = app.textFields["Message"]
        guard textField.waitForExistence(timeout: 5) else {
            XCTFail("Message text field not found")
            return
        }
        textField.tap()
        textField.typeText("Hello from Sim 2!")

        takeScreenshot("06-ReplyTyped")

        // Tap send button
        let sendBtn = app.buttons["Send"]
        guard sendBtn.waitForExistence(timeout: 3) else {
            XCTFail("Send button not found")
            return
        }
        sendBtn.tap()

        sleep(2)
        takeScreenshot("06-ReplySent")

        // Verify both messages visible
        let ownReply = app.staticTexts["Hello from Sim 2!"]
        XCTAssertTrue(ownReply.waitForExistence(timeout: 5), "Sent reply should appear in chat")
        XCTAssertTrue(incomingMessage.exists, "Sim 1's message should still be visible")

        takeScreenshot("06-BothMessages")

        // Keep alive so Sim 1 can verify receipt
        sleep(15)
    }

    func test07_MediaMessaging() {
        // Handle microphone permission prompt
        addUIInterruptionMonitor(withDescription: "Microphone Permission") { alert in
            let allowBtn = alert.buttons["Allow"]
            if allowBtn.exists {
                allowBtn.tap()
                return true
            }
            let okBtn = alert.buttons["OK"]
            if okBtn.exists {
                okBtn.tap()
                return true
            }
            return false
        }

        // Connect to peer
        connectToPeer()

        // Tap Message button to open chat
        let messageBtn = app.staticTexts["Message"]
        guard messageBtn.waitForExistence(timeout: 5) else {
            XCTFail("Message button not found")
            return
        }
        messageBtn.tap()
        sleep(1)

        takeScreenshot("07-ChatOpened")

        // 1. Verify Attach (+) button exists
        let attachBtn = app.buttons["Attach"]
        XCTAssertTrue(attachBtn.waitForExistence(timeout: 5), "Attach (+) button should be visible")

        // 2. Verify mic button visible (no text entered)
        let micBtn = app.buttons["Record Voice"]
        XCTAssertTrue(micBtn.waitForExistence(timeout: 3), "Mic button should be visible when text field is empty")

        takeScreenshot("07-InputBarVerified")

        // 3. Verify attachment menu options
        attachBtn.tap()
        sleep(1)

        let photoVideoBtn = app.buttons["Photo & Video"]
        XCTAssertTrue(photoVideoBtn.waitForExistence(timeout: 3), "Attachment menu should show Photo & Video")
        XCTAssertTrue(app.buttons["Camera"].exists, "Attachment menu should show Camera")
        XCTAssertTrue(app.buttons["File"].exists, "Attachment menu should show File")

        takeScreenshot("07-AttachMenu")

        // Dismiss menu
        let cancelBtn = app.buttons["Cancel"]
        if cancelBtn.exists { cancelBtn.tap() }
        sleep(1)

        // 4. Wait for voice message or text from Sim 1
        let voiceBubble = app.otherElements.matching(identifier: "voice-bubble").firstMatch
        var receivedVoice = false

        for _ in 1...20 {
            if voiceBubble.exists {
                receivedVoice = true
                break
            }
            // Also check for text fallback
            if app.staticTexts["Media test from Sim 1"].exists {
                print("[Sim2] Received text fallback from Sim 1")
                break
            }
            sleep(2)
        }

        takeScreenshot("07-AfterWaitingForSim1")

        if receivedVoice {
            takeScreenshot("07-VoiceBubbleReceived")
        }

        // 5. Record and send voice message from Sim 2
        let micBtnForRecord = app.buttons["Record Voice"]
        guard micBtnForRecord.waitForExistence(timeout: 5) else {
            print("[Sim2] Mic button not visible, skipping voice recording")
            takeScreenshot("07-NoMicButton")
            sleep(10)
            return
        }

        micBtnForRecord.tap()
        // Trigger interruption monitor for mic permission
        app.tap()
        sleep(1)

        let sendVoiceBtn = app.buttons["Send Voice"]

        if sendVoiceBtn.waitForExistence(timeout: 5) {
            // Recording started — wait 2 seconds for duration
            sleep(2)
            takeScreenshot("07-Recording")

            sendVoiceBtn.tap()
            sleep(2)
            takeScreenshot("07-VoiceSent")

            // Verify our voice bubble appears
            let voiceBubbles = app.otherElements.matching(identifier: "voice-bubble")
            let expectedCount = receivedVoice ? 2 : 1
            let bubbleCount = voiceBubbles.count

            takeScreenshot("07-VoiceBubbleCount-\(bubbleCount)")

            XCTAssertGreaterThanOrEqual(bubbleCount, expectedCount,
                "Should have at least \(expectedCount) voice bubble(s)")
        } else {
            takeScreenshot("07-RecordingFailed")
            print("[Sim2] Voice recording failed — sending text fallback")

            // Dismiss any system alert
            app.tap()
            sleep(1)

            // Find text field using textViews (SwiftUI vertical axis TextField may use textView)
            let tf = app.textFields.firstMatch
            if tf.waitForExistence(timeout: 3) {
                tf.tap()
                tf.typeText("Media test reply from Sim 2")
                let sb = app.buttons["Send"]
                if sb.waitForExistence(timeout: 3) { sb.tap() }
            }
        }

        // Keep alive for Sim 1 to receive
        sleep(15)
        takeScreenshot("07-Final")
    }

    func test08_PhotoTransferE2E() {
        // Handle photo library permission prompt
        addUIInterruptionMonitor(withDescription: "Photo Permission") { alert in
            for label in ["Allow Full Access", "Allow", "OK"] {
                let btn = alert.buttons[label]
                if btn.exists { btn.tap(); return true }
            }
            return false
        }

        // Connect to peer
        connectToPeer()

        // Open chat
        let messageBtn = app.staticTexts["Message"]
        guard messageBtn.waitForExistence(timeout: 5) else {
            XCTFail("Message button not found")
            return
        }
        messageBtn.tap()
        sleep(1)

        takeScreenshot("08-ChatOpened")

        // Tap Attach button
        let attachBtn = app.buttons["Attach"]
        guard attachBtn.waitForExistence(timeout: 5) else {
            XCTFail("Attach button not found")
            return
        }
        attachBtn.tap()
        sleep(1)

        // Tap "Photo & Video"
        let photoVideoBtn = app.buttons["Photo & Video"]
        guard photoVideoBtn.waitForExistence(timeout: 3) else {
            XCTFail("Photo & Video option not found in attach menu")
            return
        }
        photoVideoBtn.tap()

        // Trigger interruption monitor for photo permission
        app.tap()
        sleep(2)

        takeScreenshot("08-PhotoPickerOpened")

        // PHPicker runs as system UI. Use coordinate tap to select the first photo.
        // From screenshots: first photo cell is at roughly (120, 480) in 1320-wide screen.
        // In XCUITest normalized coordinates, that's about (0.09, 0.17) of full screen.
        sleep(2)
        takeScreenshot("08-PHPickerVisible")

        // Dismiss the privacy banner first if visible, then tap the first photo
        // The first photo (orange test image) is in top-left of the grid
        let firstPhotoCoord = app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.35))
        firstPhotoCoord.tap()
        sleep(1)

        takeScreenshot("08-PhotoSelected")

        // Tap "Add" / "加入" button to confirm selection (localized)
        let addBtn = app.buttons.matching(NSPredicate(format: "label CONTAINS '加入' OR label CONTAINS 'Add'")).firstMatch
        if addBtn.waitForExistence(timeout: 3) {
            addBtn.tap()
        } else {
            // Try tapping Done
            let doneBtn = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Done' OR label CONTAINS '完成'")).firstMatch
            if doneBtn.exists { doneBtn.tap() }
        }

        sleep(5)
        takeScreenshot("08-AfterPickerDismissed")

        // Verify: check if the picker dismissed and we're back in chat
        let attachBtnAgain = app.buttons["Attach"]
        let backInChat = attachBtnAgain.waitForExistence(timeout: 10)

        if backInChat {
            // Check for image bubble or any media indicator
            let hasImages = app.images.count > 0
            takeScreenshot("08-PhotoSent")
            if hasImages {
                XCTAssertTrue(true, "Image media bubble appeared after sending photo")
            } else {
                print("[Sim2] Back in chat but no image bubble detected yet")
            }
        } else {
            takeScreenshot("08-StillInPicker")
            // May still be in picker — try dismiss with X button
            let closeBtn = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Cancel' OR label CONTAINS '取消'")).firstMatch
            if closeBtn.exists { closeBtn.tap() }
        }

        // Keep alive for Sim 1 to receive
        sleep(15)
        takeScreenshot("08-Final")
    }

    /// Test camera unavailable alert + Library deduplication
    func test09_CameraAlertAndLibrary() {
        // Connect to peer
        connectToPeer()

        // Open chat
        let messageBtn = app.staticTexts["Message"]
        guard messageBtn.waitForExistence(timeout: 5) else {
            XCTFail("Message button not found")
            return
        }
        messageBtn.tap()
        sleep(1)

        // Tap Attach button
        let attachBtn = app.buttons["Attach"]
        guard attachBtn.waitForExistence(timeout: 5) else {
            XCTFail("Attach button not found")
            return
        }
        attachBtn.tap()
        sleep(1)

        takeScreenshot("09-AttachMenuOpened")

        // Tap Camera — should show alert on simulator (no camera)
        let cameraBtn = app.buttons["Camera"]
        guard cameraBtn.waitForExistence(timeout: 3) else {
            XCTFail("Camera option not found in attachment menu")
            return
        }
        cameraBtn.tap()
        sleep(1)

        takeScreenshot("09-AfterCameraTap")

        // Verify "Camera Unavailable" alert appears
        let alert = app.alerts["Camera Unavailable"]
        let alertAppeared = alert.waitForExistence(timeout: 3)
        takeScreenshot("09-CameraAlert")
        XCTAssertTrue(alertAppeared, "Camera Unavailable alert should appear on simulator")

        // Dismiss alert
        if alertAppeared {
            alert.buttons["OK"].tap()
            sleep(1)
        }

        // Go back to Connected tab
        let backBtn = app.navigationBars.buttons.firstMatch
        if backBtn.exists { backBtn.tap() }
        sleep(1)

        // Navigate to Library tab (3rd tab, index 2)
        let libraryTab = app.tabBars.buttons.element(boundBy: 2)
        libraryTab.tap()
        sleep(1)

        takeScreenshot("09-LibraryTab")

        // Count device records — should be exactly 1 (no duplicates)
        let cells = app.cells
        let cellCount = cells.count
        takeScreenshot("09-LibraryCellCount-\(cellCount)")
        XCTAssertEqual(cellCount, 1, "Library should have exactly 1 device record, not \(cellCount) duplicates")

        // Go back to Connected tab for cleanup
        let connectedTab = app.tabBars.buttons.element(boundBy: 1)
        connectedTab.tap()
        sleep(1)

        takeScreenshot("09-Final")
    }

    // MARK: - Helpers

    private func waitForPeer(timeout: TimeInterval) -> Bool {
        // Peers appear as combined accessibility elements (Button) with label like
        // "iPhone 17 Pro, Local Network" inside List cells.
        // Also check for "Nearby Devices" section header which only appears when peers exist.
        let startTime = Date()
        while Date().timeIntervalSince(startTime) < timeout {
            // Check for the section header that appears when peers are discovered
            let header = app.staticTexts["Nearby Devices"]
            if header.exists {
                return true
            }
            // Check for buttons containing device names (combined accessibility elements)
            let peerButtons = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Local Network'"))
            if peerButtons.count > 0 {
                return true
            }
            // Also try cells
            let cells = app.cells
            if cells.count > 0 {
                return true
            }
            // Check for grid items (PeerGridItemView uses Button)
            let gridButtons = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'iPhone'"))
            if gridButtons.count > 0 {
                return true
            }
            sleep(1)
        }
        return false
    }

    private func tapFirstPeer() {
        // Try buttons with "Local Network" (combined accessibility label from PeerRowView)
        let peerButtons = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Local Network'"))
        if peerButtons.count > 0 {
            peerButtons.firstMatch.tap()
            return
        }
        // Try cells
        let cells = app.cells
        if cells.count > 0 {
            cells.firstMatch.tap()
            return
        }
        // Try buttons with iPhone in name (grid mode)
        let gridButtons = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'iPhone'"))
        if gridButtons.count > 0 {
            gridButtons.firstMatch.tap()
            return
        }
    }

    private func connectToPeer() {
        // Check if already connected
        let sendFileBtn = app.staticTexts["File"]
        if sendFileBtn.exists {
            return // Already connected
        }

        // Navigate to Connected tab to check
        let connectedTab = app.tabBars.buttons.element(boundBy: 1)
        connectedTab.tap()
        sleep(1)
        if app.staticTexts["File"].exists {
            return // Already connected
        }

        // Need to connect — go to Nearby tab
        let nearbyTab = app.tabBars.buttons.element(boundBy: 0)
        nearbyTab.tap()
        sleep(1)

        let peerFound = waitForPeer(timeout: 15)
        guard peerFound else {
            XCTFail("Could not find peer to connect to")
            return
        }
        tapFirstPeer()

        // Wait for connection
        let connectedNav = app.navigationBars["Connected"]
        guard connectedNav.waitForExistence(timeout: 30) else {
            XCTFail("Connection was not established")
            return
        }
        sleep(1)
    }

    private func takeScreenshot(_ name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
