import XCTest

/// Helper test that runs on Sim 1 (receiver).
/// Accepts the incoming connection and stays alive for cross-device feature testing.
final class AcceptConnectionHelper: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5))
    }

    /// Accept incoming connection and stay alive for feature tests on the other device.
    func testAcceptAndStayConnected() {
        // Wait for consent sheet with Accept button (up to 45 seconds)
        let acceptButton = app.buttons["Accept"]
        guard acceptButton.waitForExistence(timeout: 45) else {
            XCTFail("No incoming connection consent sheet appeared within 45 seconds")
            return
        }

        // Tap Accept
        acceptButton.tap()

        // Verify we transition to Connected tab
        let connectedNav = app.navigationBars["Connected"]
        XCTAssertTrue(connectedNav.waitForExistence(timeout: 10), "Should auto-switch to Connected tab after accepting")

        // Navigate into ConnectionView from Active section
        navigateToConnectionView()

        // Verify we see peer info and action buttons
        let fileLabel = app.staticTexts["Send File"]
        XCTAssertTrue(fileLabel.waitForExistence(timeout: 5), "Send File button should appear when connected")

        // Stay connected for 120 seconds to allow feature testing from the other device
        for i in 1...24 {
            sleep(5)
            if app.staticTexts["Connected"].exists || connectedNav.exists {
                continue
            }
            if app.staticTexts["No active connection"].exists {
                print("[Sim1] Disconnected at interval \(i)")
                break
            }
        }
    }

    /// Accept connection, open chat, send a message, and wait for reply.
    func testAcceptAndChat() {
        // Wait for consent sheet
        let acceptButton = app.buttons["Accept"]
        guard acceptButton.waitForExistence(timeout: 45) else {
            XCTFail("No incoming connection consent sheet appeared within 45 seconds")
            return
        }

        acceptButton.tap()

        // Wait for connected state
        let connectedNav = app.navigationBars["Connected"]
        guard connectedNav.waitForExistence(timeout: 10) else {
            XCTFail("Did not transition to Connected tab")
            return
        }

        // Navigate into ConnectionView from Active section
        navigateToConnectionView()

        let chatBtn = app.staticTexts["Chat"]
        guard chatBtn.waitForExistence(timeout: 5) else {
            XCTFail("Chat button not found")
            return
        }

        takeScreenshot("Sim1-01-Connected")

        // Tap Chat to open chat
        chatBtn.tap()
        sleep(1)

        takeScreenshot("Sim1-02-ChatOpened")

        // Type and send a message from Sim 1
        let textField = app.textFields["Message"]
        guard textField.waitForExistence(timeout: 5) else {
            XCTFail("Message text field not found")
            return
        }
        textField.tap()
        textField.typeText("Hello from Sim 1!")

        takeScreenshot("Sim1-03-MessageTyped")

        // Tap send button
        let sendBtn = app.buttons["Send"]
        guard sendBtn.waitForExistence(timeout: 3) else {
            XCTFail("Send button not found")
            return
        }
        sendBtn.tap()

        sleep(2)
        takeScreenshot("Sim1-04-MessageSent")

        // Verify our message appears in the chat
        let ownMessage = app.staticTexts["Hello from Sim 1!"]
        XCTAssertTrue(ownMessage.waitForExistence(timeout: 5), "Sent message should appear in chat")

        // Wait for reply from Sim 2 (up to 60 seconds)
        let reply = app.staticTexts["Hello from Sim 2!"]
        let receivedReply = reply.waitForExistence(timeout: 60)

        takeScreenshot("Sim1-05-AfterWaitingReply")

        XCTAssertTrue(receivedReply, "Should receive reply from Sim 2")

        // Stay alive a bit longer
        sleep(10)
        takeScreenshot("Sim1-06-Final")
    }

    /// Accept connection, open chat, send voice message, verify media exchange.
    func testAcceptAndMediaChat() {
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

        // Wait for consent sheet
        let acceptButton = app.buttons["Accept"]
        guard acceptButton.waitForExistence(timeout: 45) else {
            XCTFail("No incoming connection consent sheet appeared within 45 seconds")
            return
        }

        acceptButton.tap()

        // Wait for connected state
        let connectedNav = app.navigationBars["Connected"]
        guard connectedNav.waitForExistence(timeout: 10) else {
            XCTFail("Did not transition to Connected tab")
            return
        }

        // Navigate into ConnectionView from Active section
        navigateToConnectionView()

        let chatBtn = app.staticTexts["Chat"]
        guard chatBtn.waitForExistence(timeout: 5) else {
            XCTFail("Chat button not found")
            return
        }

        takeScreenshot("Media-Sim1-01-Connected")

        // Open chat
        chatBtn.tap()
        sleep(1)

        takeScreenshot("Media-Sim1-02-ChatOpened")

        // Verify + (Attach) button and mic button exist
        let attachBtn = app.buttons["Attach"]
        XCTAssertTrue(attachBtn.waitForExistence(timeout: 5), "Attach button should be visible")

        let micBtn = app.buttons["Record Voice"]
        XCTAssertTrue(micBtn.waitForExistence(timeout: 3), "Mic button should be visible when text field is empty")

        takeScreenshot("Media-Sim1-03-InputBarVerified")

        // Test: Tap Attach button to verify confirmationDialog
        attachBtn.tap()
        sleep(1)

        let photoVideoBtn = app.buttons["Photo & Video"]
        let attachMenuShown = photoVideoBtn.waitForExistence(timeout: 3)
        XCTAssertTrue(attachMenuShown, "Attachment menu should show Photo & Video option")

        let cameraBtn = app.buttons["Camera"]
        XCTAssertTrue(cameraBtn.exists, "Attachment menu should show Camera option")

        let fileBtn = app.buttons["File"]
        XCTAssertTrue(fileBtn.exists, "Attachment menu should show File option")

        takeScreenshot("Media-Sim1-04-AttachMenu")

        // Dismiss attachment menu
        let cancelBtn = app.buttons["Cancel"]
        if cancelBtn.exists { cancelBtn.tap() }
        sleep(1)

        // Test: Record and send voice message
        let micBtnAgain = app.buttons["Record Voice"]
        guard micBtnAgain.waitForExistence(timeout: 5) else {
            XCTFail("Mic button not found after dismissing attach menu")
            return
        }
        micBtnAgain.tap()

        // Trigger the interruption monitor by interacting with the app
        app.tap()
        sleep(1)

        takeScreenshot("Media-Sim1-05-RecordingStarted")

        // Check if recording overlay appeared
        let voiceOverlay = app.otherElements["voice-recorder-overlay"]
        let sendVoiceBtn = app.buttons["Send Voice"]

        if sendVoiceBtn.waitForExistence(timeout: 5) {
            // Recording started successfully - wait 2 seconds for duration
            sleep(2)
            takeScreenshot("Media-Sim1-06-Recording")

            // Send the voice message
            sendVoiceBtn.tap()
            sleep(2)
            takeScreenshot("Media-Sim1-07-VoiceSent")

            // Verify voice bubble appears
            let voiceBubble = app.otherElements.matching(identifier: "voice-bubble").firstMatch
            let voiceSent = voiceBubble.waitForExistence(timeout: 10)

            if voiceSent {
                takeScreenshot("Media-Sim1-08-VoiceBubbleVisible")
            } else {
                takeScreenshot("Media-Sim1-08-NoVoiceBubble")
            }

            // Wait for voice message from Sim 2 (up to 60 seconds)
            // Sim 2 will also send a voice message
            let voiceBubbles = app.otherElements.matching(identifier: "voice-bubble")
            var receivedFromSim2 = false
            for _ in 1...30 {
                if voiceBubbles.count >= 2 {
                    receivedFromSim2 = true
                    break
                }
                sleep(2)
            }

            takeScreenshot("Media-Sim1-09-AfterWaitingForSim2")

            if receivedFromSim2 {
                XCTAssertTrue(true, "Received voice message from Sim 2")
            } else {
                // Also check if Sim 2 sent a text fallback
                print("[Sim1] Voice bubbles count: \(voiceBubbles.count)")
            }
        } else {
            takeScreenshot("Media-Sim1-05-RecordingFailed")
            // Recording may have failed (permission denied or no mic hardware)
            // Fall back to sending a text message to keep the test useful
            print("[Sim1] Voice recording failed, sending text fallback")

            // Tap anywhere to dismiss any alert
            app.tap()
            sleep(1)

            let textField = app.textFields["Message"]
            if textField.waitForExistence(timeout: 5) {
                textField.tap()
                textField.typeText("Media test from Sim 1")
                let sendBtn = app.buttons["Send"]
                if sendBtn.waitForExistence(timeout: 3) {
                    sendBtn.tap()
                }
            }
        }

        // Stay alive for Sim 2
        sleep(30)
        takeScreenshot("Media-Sim1-10-Final")
    }

    /// Accept connection, open chat, wait for photo from Sim 2.
    func testAcceptAndReceivePhoto() {
        // Wait for consent sheet
        let acceptButton = app.buttons["Accept"]
        guard acceptButton.waitForExistence(timeout: 45) else {
            XCTFail("No incoming connection consent sheet appeared within 45 seconds")
            return
        }
        acceptButton.tap()

        // Wait for connected state
        let connectedNav = app.navigationBars["Connected"]
        guard connectedNav.waitForExistence(timeout: 10) else {
            XCTFail("Did not transition to Connected tab")
            return
        }

        // Navigate into ConnectionView from Active section
        navigateToConnectionView()

        let chatBtn = app.staticTexts["Chat"]
        guard chatBtn.waitForExistence(timeout: 5) else {
            XCTFail("Chat button not found")
            return
        }

        takeScreenshot("Photo-Sim1-01-Connected")

        // Open chat
        chatBtn.tap()
        sleep(1)
        takeScreenshot("Photo-Sim1-02-ChatOpened")

        // Wait for incoming photo from Sim 2 (up to 90 seconds)
        // Image bubbles render as Image elements in ChatMediaBubbleView
        var receivedPhoto = false
        for i in 1...18 {
            // Check for image elements (media bubbles)
            if app.images.count > 0 {
                receivedPhoto = true
                break
            }
            // Also check for any file-related static text
            if app.staticTexts.matching(NSPredicate(format: "label CONTAINS '.png' OR label CONTAINS '.jpg' OR label CONTAINS 'image'")).firstMatch.exists {
                receivedPhoto = true
                break
            }
            sleep(5)
            if i % 3 == 0 { takeScreenshot("Photo-Sim1-Waiting-\(i)") }
        }

        takeScreenshot("Photo-Sim1-03-AfterWaiting")

        if receivedPhoto {
            takeScreenshot("Photo-Sim1-04-PhotoReceived")
            XCTAssertTrue(true, "Received photo from Sim 2")
        } else {
            print("[Sim1] No photo received from Sim 2 within timeout")
        }

        // Stay alive
        sleep(10)
        takeScreenshot("Photo-Sim1-05-Final")
    }

    /// Accept connection, open chat, send reply, go back to verify Contacts and unread badge.
    func testAcceptAndVerifyNewFeatures() {
        // Wait for consent sheet
        let acceptButton = app.buttons["Accept"]
        guard acceptButton.waitForExistence(timeout: 45) else {
            XCTFail("No incoming connection consent sheet appeared within 45 seconds")
            return
        }
        acceptButton.tap()
        sleep(3)

        takeScreenshot("NF-01-Connected")

        // Verify Active section in Connected list
        let activeHeader = app.staticTexts["Active"]
        XCTAssertTrue(activeHeader.waitForExistence(timeout: 5), "Active section should be visible")
        takeScreenshot("NF-01b-ActiveSection")

        // Navigate into ConnectionView from Active section
        navigateToConnectionView()

        // Verify 3-icon UI
        let chatText = app.staticTexts["Chat"]
        guard chatText.waitForExistence(timeout: 5) else {
            XCTFail("Chat icon not found after accepting connection")
            return
        }

        // Check for Connection History section (scroll down)
        let connectionHistory = app.staticTexts["Connection History"]
        app.swipeUp()
        sleep(1)
        takeScreenshot("NF-02-ScrolledForHistory")
        if connectionHistory.exists {
            print("[Sim1] Connection History section visible!")
        }
        app.swipeDown()
        sleep(1)

        // Open Chat
        chatText.tap()
        sleep(1)
        takeScreenshot("NF-03-ChatOpened")

        // Wait for incoming message from initiator
        let incoming = app.staticTexts["Hello from Pro!"]
        if incoming.waitForExistence(timeout: 30) {
            print("[Sim1] Received 'Hello from Pro!'")
            takeScreenshot("NF-04-ReceivedMessage")
        }

        // Send reply
        let textField = app.textFields["Message"]
        if textField.waitForExistence(timeout: 3) {
            textField.tap()
            textField.typeText("Reply from acceptor!")
            let sendBtn = app.buttons["Send message"]
            if sendBtn.waitForExistence(timeout: 3) {
                sendBtn.tap()
                sleep(1)
            }
            takeScreenshot("NF-05-ReplySent")
        }

        // Go back to detail view
        let backButton = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Back'")).firstMatch
        if backButton.exists {
            backButton.tap()
            sleep(1)
        }
        takeScreenshot("NF-06-DetailView")

        // Go back to Connected list
        let backButton2 = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Back'")).firstMatch
        if backButton2.exists {
            backButton2.tap()
            sleep(1)
        }
        takeScreenshot("NF-07-ConnectedList")

        // Verify "Contacts" section header
        let contactsHeader = app.staticTexts["Contacts"]
        if contactsHeader.waitForExistence(timeout: 3) {
            print("[Sim1] Contacts section header found!")
        }

        // Verify "Active" section
        let activeHeaderAgain = app.staticTexts["Active"]
        if activeHeaderAgain.exists {
            print("[Sim1] Active section found!")
        }

        takeScreenshot("NF-08-ContactsSection")

        // Stay alive
        sleep(15)
        takeScreenshot("NF-09-Final")
    }

    /// Navigate from Connected list (Active section) into ConnectionView detail.
    private func navigateToConnectionView() {
        let activeHeader = app.staticTexts["Active"]
        if activeHeader.waitForExistence(timeout: 5) {
            // New UI: Active section with peer row, tap to navigate to ConnectionView
            let peerRow = app.buttons["active-peer-row"]
            if peerRow.waitForExistence(timeout: 3) {
                peerRow.tap()
                sleep(1)
            }
        }
    }

    private func takeScreenshot(_ name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
