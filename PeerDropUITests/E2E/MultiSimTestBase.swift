import XCTest

// ═══════════════════════════════════════════════════════════════════════════
// Multi-Simulator Test Base Class
//
// Provides file-based synchronization between two simulators running
// coordinated E2E tests. Uses /tmp/peerdrop-test-sync/ for checkpoint
// signals and verification data.
//
// SYNCHRONIZATION FLOW:
//   Initiator                              Acceptor
//       |                                      |
//       | signal("initiator-ready")            |
//       |────────────────────────────────────▶|
//       |                     wait("initiator-ready")
//       |                                      |
//       |◀────────────────────────────────────|
//       | wait("acceptor-ready")  signal("acceptor-ready")
//
// ═══════════════════════════════════════════════════════════════════════════

/// Base class for multi-simulator E2E tests providing synchronization primitives
class MultiSimTestBase: XCTestCase {

    // MARK: - Configuration

    /// Sync directory shared between simulators (host filesystem)
    static let syncDirectory = "/tmp/peerdrop-test-sync"

    /// Role of this test instance
    enum TestRole: String {
        case initiator
        case acceptor
    }

    /// Override in subclass to specify role
    var role: TestRole { fatalError("Subclass must override 'role'") }

    /// Test timeout for waiting operations
    var defaultTimeout: TimeInterval { 30 }

    /// XCUIApplication instance
    var app: XCUIApplication!

    // MARK: - Setup & Teardown

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()

        // Wait for app to be ready
        XCTAssertTrue(
            app.tabBars.firstMatch.waitForExistence(timeout: 10),
            "App should launch with tab bar visible"
        )

        // Ensure sync directory exists
        ensureSyncDirectoryExists()

        // Log role
        print("[\(role.rawValue.uppercased())] Test starting: \(name)")
    }

    override func tearDownWithError() throws {
        // Take final screenshot
        screenshot("\(role.rawValue)-final")

        // Signal completion for this role
        signalCheckpoint("\(role.rawValue)-complete")

        print("[\(role.rawValue.uppercased())] Test finished: \(name)")
    }

    // MARK: - Sync Directory Management

    private func ensureSyncDirectoryExists() {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: Self.syncDirectory) {
            try? fileManager.createDirectory(
                atPath: Self.syncDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o777]
            )
        }
    }

    /// Get the current test ID from the test name
    var testID: String {
        // Extract test ID from method name like "test_DISC_01"
        let methodName = name.components(separatedBy: " ").last ?? name
        return methodName
            .replacingOccurrences(of: "test_", with: "")
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: "]", with: "")
    }

    /// Directory for this specific test run
    private var testSyncDirectory: String {
        "\(Self.syncDirectory)/\(testID)"
    }

    // MARK: - Checkpoint Signals

    /// Signal that this side has reached a checkpoint
    /// - Parameter name: Checkpoint name (e.g., "ready", "connected", "message-sent")
    func signalCheckpoint(_ name: String) {
        let checkpointPath = "\(testSyncDirectory)/\(role.rawValue)-\(name)"
        try? FileManager.default.createDirectory(
            atPath: testSyncDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let timestamp = Date().timeIntervalSince1970
        try? "\(timestamp)".write(toFile: checkpointPath, atomically: true, encoding: .utf8)

        print("[\(role.rawValue.uppercased())] Signaled checkpoint: \(name)")
    }

    /// Wait for the other side to reach a checkpoint
    /// - Parameters:
    ///   - name: Checkpoint name to wait for
    ///   - timeout: Maximum time to wait
    /// - Returns: true if checkpoint was reached, false if timed out
    @discardableResult
    func waitForCheckpoint(_ name: String, timeout: TimeInterval? = nil) -> Bool {
        let effectiveTimeout = timeout ?? defaultTimeout
        let otherRole: TestRole = role == .initiator ? .acceptor : .initiator
        let checkpointPath = "\(testSyncDirectory)/\(otherRole.rawValue)-\(name)"

        print("[\(role.rawValue.uppercased())] Waiting for checkpoint: \(name) (timeout: \(effectiveTimeout)s)")

        let startTime = Date()
        while Date().timeIntervalSince(startTime) < effectiveTimeout {
            if FileManager.default.fileExists(atPath: checkpointPath) {
                print("[\(role.rawValue.uppercased())] Checkpoint reached: \(name)")
                return true
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        print("[\(role.rawValue.uppercased())] Checkpoint timeout: \(name)")
        return false
    }

    /// Wait for own checkpoint to be acknowledged by the other side
    /// Useful for two-way handshakes
    func syncWithPeer(localCheckpoint: String, peerCheckpoint: String, timeout: TimeInterval? = nil) -> Bool {
        signalCheckpoint(localCheckpoint)
        return waitForCheckpoint(peerCheckpoint, timeout: timeout)
    }

    // MARK: - Verification Data Exchange

    /// Write verification data that the other side can read
    /// - Parameters:
    ///   - key: Data key
    ///   - value: Data value
    func writeVerificationResult(_ key: String, value: String) {
        try? FileManager.default.createDirectory(
            atPath: testSyncDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let dataPath = "\(testSyncDirectory)/data-\(role.rawValue)-\(key)"
        try? value.write(toFile: dataPath, atomically: true, encoding: .utf8)

        print("[\(role.rawValue.uppercased())] Wrote verification data: \(key) = \(value)")
    }

    /// Read verification data written by the other side
    /// - Parameter key: Data key
    /// - Returns: Data value or nil if not found
    func readVerificationResult(_ key: String) -> String? {
        let otherRole: TestRole = role == .initiator ? .acceptor : .initiator
        let dataPath = "\(testSyncDirectory)/data-\(otherRole.rawValue)-\(key)"

        if let value = try? String(contentsOfFile: dataPath, encoding: .utf8) {
            print("[\(role.rawValue.uppercased())] Read verification data: \(key) = \(value)")
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// Wait for verification data from the other side
    func waitForVerificationData(_ key: String, timeout: TimeInterval? = nil) -> String? {
        let effectiveTimeout = timeout ?? defaultTimeout
        let startTime = Date()

        while Date().timeIntervalSince(startTime) < effectiveTimeout {
            if let value = readVerificationResult(key) {
                return value
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return nil
    }

    // MARK: - Screenshot Helpers

    /// Take and attach a screenshot with a descriptive name
    func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "\(testID)-\(role.rawValue)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Common UI Helpers

    /// Ensure the app is online (tap "Go online" if needed)
    func ensureOnline() {
        let goOnlineBtn = app.navigationBars.buttons["Go online"]
        if goOnlineBtn.waitForExistence(timeout: 2) {
            goOnlineBtn.tap()
            sleep(2)
        }
    }

    /// Go offline
    func goOffline() {
        let goOfflineBtn = app.navigationBars.buttons["Go offline"]
        if goOfflineBtn.waitForExistence(timeout: 3) {
            goOfflineBtn.tap()
            sleep(2)
        }
    }

    /// Go back online
    func goOnline() {
        let goOnlineBtn = app.navigationBars.buttons["Go online"]
        if goOnlineBtn.waitForExistence(timeout: 3) {
            goOnlineBtn.tap()
            sleep(2)
        }
    }

    /// Switch to a tab
    func switchToTab(_ name: String) {
        app.tabBars.buttons[name].tap()
        sleep(1)
    }

    /// Find a peer device in the discovery list
    func findPeer(timeout: TimeInterval = 30) -> XCUIElement? {
        let peer = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'iPhone'")
        ).firstMatch
        if peer.waitForExistence(timeout: timeout) { return peer }

        let cell = app.cells.matching(
            NSPredicate(format: "label CONTAINS 'iPhone'")
        ).firstMatch
        if cell.waitForExistence(timeout: 3) { return cell }

        let text = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'iPhone'")
        ).firstMatch
        if text.waitForExistence(timeout: 3) { return text }

        return nil
    }

    /// Tap on a peer element
    func tapPeer(_ peer: XCUIElement) {
        if peer.elementType == .cell {
            peer.tap()
        } else {
            peer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    /// Wait for connection to be established (Connected tab selected)
    func waitForConnected(timeout: Int = 30) -> Bool {
        let connectedTab = app.tabBars.buttons["Connected"]
        for _ in 0..<timeout {
            if connectedTab.isSelected { return true }
            sleep(1)
        }
        return false
    }

    /// Wait for consent sheet and return the Accept button
    func waitForConsent(timeout: Int = 60) -> Bool {
        let accept = app.buttons["Accept"]
        for _ in 0..<timeout {
            if accept.exists { return true }
            sleep(1)
        }
        return false
    }

    /// Navigate to the ConnectionView for the active peer
    func navigateToConnectionView() {
        let peerRow = app.buttons["active-peer-row"]
        if peerRow.waitForExistence(timeout: 5) {
            peerRow.tap()
            sleep(1)
        }
    }

    /// Navigate to Chat from ConnectionView
    func navigateToChat() {
        // Try accessibility identifier first
        let chatButton = app.buttons["chat-button"]
        if chatButton.waitForExistence(timeout: 5) {
            chatButton.tap()
            sleep(1)
            return
        }
        // Fallback to label
        let chatLabel = app.staticTexts["Chat"]
        if chatLabel.waitForExistence(timeout: 3) {
            chatLabel.tap()
            sleep(1)
        }
    }

    /// Tap Send File button in ConnectionView
    func tapSendFile() {
        let sendFileButton = app.buttons["send-file-button"]
        if sendFileButton.waitForExistence(timeout: 5) {
            sendFileButton.tap()
            sleep(1)
            return
        }
        // Fallback to label
        let sendFileLabel = app.staticTexts["Send File"]
        if sendFileLabel.waitForExistence(timeout: 3) {
            sendFileLabel.tap()
            sleep(1)
        }
    }

    /// Check if Send File button exists
    func sendFileButtonExists(timeout: TimeInterval = 5) -> Bool {
        let sendFileButton = app.buttons["send-file-button"]
        if sendFileButton.waitForExistence(timeout: timeout) { return true }
        let sendFileLabel = app.staticTexts["Send File"]
        return sendFileLabel.waitForExistence(timeout: 2)
    }

    /// Check if Chat button exists
    func chatButtonExists(timeout: TimeInterval = 5) -> Bool {
        let chatButton = app.buttons["chat-button"]
        if chatButton.waitForExistence(timeout: timeout) { return true }
        let chatLabel = app.staticTexts["Chat"]
        return chatLabel.waitForExistence(timeout: 2)
    }

    /// Check if Voice Call button exists
    func voiceCallButtonExists(timeout: TimeInterval = 5) -> Bool {
        let voiceButton = app.buttons["voice-call-button"]
        if voiceButton.waitForExistence(timeout: timeout) { return true }
        let voiceLabel = app.staticTexts["Voice Call"]
        return voiceLabel.waitForExistence(timeout: 2)
    }

    /// Send a chat message
    func sendChatMessage(_ text: String) {
        let field = app.textFields["Message"]
        if field.waitForExistence(timeout: 5) {
            field.tap()
            field.typeText(text)
            let send = app.buttons["Send"]
            if send.waitForExistence(timeout: 2) { send.tap() }
            sleep(1)
        }
    }

    /// Verify a message exists in chat
    func verifyMessageExists(_ text: String, timeout: TimeInterval = 10) -> Bool {
        let message = app.staticTexts[text]
        return message.waitForExistence(timeout: timeout)
    }

    /// Go back one screen
    func goBack() {
        let back = app.navigationBars.buttons.firstMatch
        if back.exists {
            back.tap()
            sleep(1)
        }
    }

    /// Disconnect from the current peer
    func disconnectFromPeer() {
        let btn = app.buttons.matching(identifier: "Disconnect").firstMatch
        if btn.waitForExistence(timeout: 5) {
            btn.tap()
            sleep(1)
            let sheet = app.sheets.firstMatch
            if sheet.waitForExistence(timeout: 3) {
                sheet.buttons["Disconnect"].tap()
            }
            sleep(2)
        }
    }

    // MARK: - Assertions with Sync

    /// Assert with checkpoint synchronization
    func assertWithSync(
        _ condition: Bool,
        checkpoint: String,
        message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if condition {
            signalCheckpoint("\(checkpoint)-passed")
        } else {
            signalCheckpoint("\(checkpoint)-failed")
            writeVerificationResult("\(checkpoint)-error", value: message)
        }
        XCTAssertTrue(condition, message, file: file, line: line)
    }
}

// MARK: - Initiator Base Class

/// Base class for initiator-side tests
class E2EInitiatorTestBase: MultiSimTestBase {
    override var role: TestRole { .initiator }

    /// Standard initiator setup: ensure online, wait for acceptor
    func standardInitiatorSetup() {
        ensureOnline()
        screenshot("online")

        // Signal ready and wait for acceptor
        signalCheckpoint("ready")
        XCTAssertTrue(
            waitForCheckpoint("ready", timeout: 60),
            "Acceptor should signal ready"
        )
    }
}

// MARK: - Acceptor Base Class

/// Base class for acceptor-side tests
class E2EAcceptorTestBase: MultiSimTestBase {
    override var role: TestRole { .acceptor }

    /// Standard acceptor setup: ensure online, signal ready, wait for initiator
    func standardAcceptorSetup() {
        ensureOnline()
        screenshot("online")

        // Wait for initiator, then signal ready
        XCTAssertTrue(
            waitForCheckpoint("ready", timeout: 60),
            "Initiator should signal ready"
        )
        signalCheckpoint("ready")
    }

    /// Accept incoming connection
    func acceptConnection() {
        XCTAssertTrue(waitForConsent(), "Should receive connection request")
        screenshot("consent-sheet")
        app.buttons["Accept"].tap()
        print("[ACCEPTOR] Accepted connection")
        sleep(3)
    }

    /// Decline incoming connection
    func declineConnection() {
        XCTAssertTrue(waitForConsent(), "Should receive connection request")
        screenshot("consent-sheet")
        app.buttons["Decline"].tap()
        print("[ACCEPTOR] Declined connection")
        sleep(2)
    }
}
