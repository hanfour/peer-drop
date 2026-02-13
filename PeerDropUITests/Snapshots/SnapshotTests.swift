//
//  SnapshotTests.swift
//  PeerDropUITests
//
//  Automated screenshot tests for App Store submission.
//  Run with: fastlane screenshots
//

import XCTest

/// Screenshot tests for Fastlane snapshot.
/// Uses SCREENSHOT_MODE to inject mock data for realistic screenshots without actual P2P connections.
@MainActor
final class SnapshotTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false

        app = XCUIApplication()
        setupSnapshot(app)

        // Enable screenshot mode via launch argument
        app.launchArguments += ["-SCREENSHOT_MODE", "1"]

        app.launch()

        // Wait for app to fully load
        // Give extra time for iPad's floating tab bar to initialize
        sleep(5)

        // Just wait and don't assert - the app UI varies between iPhone and iPad
        // Screenshots will capture whatever state the app is in
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Screenshot Tests

    /// 01: Nearby tab with discovered devices (list view)
    func test01_NearbyTab() {
        // Should already be on Nearby tab
        // Wait for app to fully load and mock data to populate
        sleep(3)

        // Wait for navigation bar to appear (works on both iPhone and iPad)
        let nearbyTitle = app.navigationBars["PeerDrop"]
        _ = nearbyTitle.waitForExistence(timeout: 8)

        snapshot("01_NearbyTab")
    }

    /// 02: Nearby tab in grid view mode
    func test02_NearbyTabGrid() {
        // Tap grid toggle button using its accessibilityIdentifier
        let gridButton = app.buttons["grid-toggle-button"]
        if gridButton.waitForExistence(timeout: 3) {
            gridButton.tap()
        }

        sleep(1)
        snapshot("02_NearbyTabGrid")
    }

    /// 03: Connected tab showing active connections and contacts
    func test03_ConnectedTab() {
        // First, set up mock connection by tapping a discovered peer
        setupMockConnection()

        // Navigate to Connected tab
        navigateToTab("Connected")
        sleep(1)

        // Should show active connection and contacts list
        let connectedTitle = app.navigationBars["Connected"]
        XCTAssertTrue(connectedTitle.waitForExistence(timeout: 5))

        snapshot("03_ConnectedTab")
    }

    /// 04: Connection detail view with peer info and action buttons
    func test04_ConnectionView() {
        setupMockConnection()

        // Navigate to connection view and wait for connected state
        _ = navigateToConnectionView()

        // Wait for action buttons to confirm connected state
        let chatButton = app.buttons["chat-button"]
        _ = chatButton.waitForExistence(timeout: 5)

        sleep(1)
        snapshot("04_ConnectionView")
    }

    /// 05: Chat view with conversation
    func test05_ChatView() {
        setupMockConnection()

        // Navigate to connection view
        _ = navigateToConnectionView()

        // Wait for and tap Chat button
        let chatButton = app.buttons["chat-button"]
        if chatButton.waitForExistence(timeout: 5) {
            chatButton.tap()
        } else {
            // Fallback: find button with message icon
            let messageButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'chat' OR label CONTAINS[c] 'message'")).firstMatch
            if messageButton.waitForExistence(timeout: 3) {
                messageButton.tap()
            }
        }

        // Wait for chat view to load with messages
        sleep(3)

        // Verify we're in chat view by checking for message input field
        let messageField = app.textFields["Message"]
        _ = messageField.waitForExistence(timeout: 3)

        snapshot("05_ChatView")
    }

    /// 06: Voice call view (in-call UI)
    func test06_VoiceCallView() {
        setupMockConnection()

        // Navigate to connection view
        _ = navigateToConnectionView()

        // Wait for and tap Voice Call button
        let voiceButton = app.buttons["voice-call-button"]
        if voiceButton.waitForExistence(timeout: 5) {
            voiceButton.tap()
        } else {
            let phoneButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'voice' OR label CONTAINS[c] 'call' OR label CONTAINS[c] 'phone'")).firstMatch
            if phoneButton.waitForExistence(timeout: 3) {
                phoneButton.tap()
            }
        }

        sleep(2)
        snapshot("06_VoiceCallView")
    }

    /// 07: Library tab with device groups and history
    func test07_LibraryTab() {
        navigateToTab("Library")
        sleep(1)

        let libraryTitle = app.navigationBars["Library"]
        XCTAssertTrue(libraryTitle.waitForExistence(timeout: 5))

        snapshot("07_LibraryTab")
    }

    /// 08: Settings screen
    func test08_Settings() {
        // Navigate to Nearby tab first (toolbar buttons are only on Nearby tab)
        navigateToTab("Nearby")
        sleep(1)

        // Open menu on Nearby tab
        let menuOpened = openSettingsMenu()

        if menuOpened {
            sleep(1)
            snapshot("08_Settings")
        } else {
            // Take screenshot of current state as fallback
            snapshot("08_Settings_Fallback")
        }
    }

    /// 09: Quick Connect (Manual Connect) sheet
    func test09_QuickConnect() {
        // Navigate to Nearby tab first (Quick Connect button is only on Nearby tab)
        navigateToTab("Nearby")
        sleep(1)

        // Find Quick Connect button using its accessibilityIdentifier
        let quickConnect = app.buttons["quick-connect-button"]

        if quickConnect.waitForExistence(timeout: 3) {
            quickConnect.tap()
        }

        sleep(1)

        // Should show Manual Connect sheet
        let manualConnectNavBar = app.navigationBars["Manual Connect"]
        if manualConnectNavBar.waitForExistence(timeout: 3) {
            snapshot("09_QuickConnect")
        } else {
            snapshot("09_QuickConnect_Fallback")
        }

        // Dismiss sheet
        let cancelButton = app.buttons["Cancel"]
        if cancelButton.exists {
            cancelButton.tap()
        }
    }

    /// 10: File transfer progress (optional - may not trigger in mock mode)
    func test10_FileTransfer() {
        setupMockConnection()

        // Navigate to connection view
        _ = navigateToConnectionView()

        // Wait for and tap Send File button
        let sendFileButton = app.buttons["send-file-button"]
        if sendFileButton.waitForExistence(timeout: 5) {
            sendFileButton.tap()
        } else {
            let fileButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'file' OR label CONTAINS[c] 'send'")).firstMatch
            if fileButton.waitForExistence(timeout: 3) {
                fileButton.tap()
            }
        }

        sleep(1)
        snapshot("10_FileTransfer")

        // Dismiss file picker if shown
        let cancelButton = app.buttons["Cancel"]
        if cancelButton.exists {
            cancelButton.tap()
        }
    }

    /// 11: Transfer history view
    func test11_TransferHistory() {
        // Navigate to Nearby tab first
        navigateToTab("Nearby")
        sleep(1)

        // Open menu and tap Transfer History
        let menuButton = app.buttons["more-options-menu"]
        if menuButton.waitForExistence(timeout: 3) {
            menuButton.tap()
            sleep(1)

            let historyButton = app.buttons["Transfer History"]
            if historyButton.waitForExistence(timeout: 3) {
                historyButton.tap()
                sleep(1)
                snapshot("11_TransferHistory")
                return
            }
        }

        snapshot("11_TransferHistory_Fallback")
    }

    /// 12: User profile view
    func test12_UserProfile() {
        // Navigate to Settings first
        navigateToTab("Nearby")
        sleep(1)

        if openSettingsMenu() {
            // Tap on user profile section (usually at top)
            let profileButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'profile' OR identifier CONTAINS[c] 'profile'")).firstMatch
            if profileButton.waitForExistence(timeout: 3) {
                profileButton.tap()
                sleep(1)
                snapshot("12_UserProfile")
                return
            }

            // Fallback: just capture Settings view again
            snapshot("12_UserProfile_Settings")
        } else {
            snapshot("12_UserProfile_Fallback")
        }
    }

    /// 13: Group detail view (from Library tab)
    func test13_GroupDetail() {
        // Navigate to Library tab
        navigateToTab("Library")
        sleep(1)

        // Look for a group row to tap
        // In screenshot mode, there should be mock groups
        let groupCell = app.cells.firstMatch
        if groupCell.waitForExistence(timeout: 3) {
            groupCell.tap()
            sleep(1)

            // Verify we're in group detail view
            let groupDetailExists = app.navigationBars.element(boundBy: 0).exists
            if groupDetailExists {
                snapshot("13_GroupDetail")
                return
            }
        }

        snapshot("13_GroupDetail_Fallback")
    }

    // MARK: - Helper Methods

    /// Set up a mock connection and wait for it to be ready.
    private func setupMockConnection() {
        // Wait for mock data to be populated
        sleep(2)

        // Navigate to Connected tab to verify connection is ready
        navigateToTab("Connected")

        // Wait for the active peer row to appear (indicates connection is established)
        let activePeerRow = app.buttons.matching(NSPredicate(format: "identifier == 'active-peer-row'")).firstMatch
        let connected = activePeerRow.waitForExistence(timeout: 5)

        if !connected {
            // Fallback: look for "Connected" text in any cell
            let connectedText = app.staticTexts["Connected"]
            _ = connectedText.waitForExistence(timeout: 3)
        }

        // Return to Nearby tab to reset navigation state
        navigateToTab("Nearby")
        sleep(1)
    }

    /// Navigate to ConnectionView and wait for connected state with action buttons.
    private func navigateToConnectionView() -> Bool {
        // Navigate to Connected tab
        navigateToTab("Connected")
        sleep(1)

        // Wait for and tap on active peer row
        let activePeerRow = app.buttons.matching(NSPredicate(format: "identifier == 'active-peer-row'")).firstMatch
        guard activePeerRow.waitForExistence(timeout: 5) else {
            // Try fallback - tap first cell
            let firstCell = app.cells.firstMatch
            if firstCell.waitForExistence(timeout: 3) {
                firstCell.tap()
                sleep(1)
                return true
            }
            return false
        }

        activePeerRow.tap()
        sleep(1)

        // Wait for the connection view to show action buttons (indicates Connected state)
        let chatButton = app.buttons["chat-button"]
        let sendFileButton = app.buttons["send-file-button"]

        // Wait up to 5 seconds for buttons to appear
        for _ in 0..<10 {
            if chatButton.exists || sendFileButton.exists {
                return true
            }
            usleep(500_000) // 0.5 seconds
        }

        return true // Continue anyway for screenshot
    }

    /// Open the Settings screen via the ellipsis menu.
    private func openSettingsMenu() -> Bool {
        // Find menu button using its accessibilityIdentifier
        let menuButton = app.buttons["more-options-menu"]
        if menuButton.waitForExistence(timeout: 3) {
            menuButton.tap()
            sleep(1)
        } else {
            // Fallback: last button in navigation bar
            let navBar = app.navigationBars["PeerDrop"]
            let buttons = navBar.buttons
            if buttons.count > 0 {
                buttons.element(boundBy: buttons.count - 1).tap()
                sleep(1)
            } else {
                return false
            }
        }

        // Tap Settings in the menu - SwiftUI menu items appear as buttons
        let settingsButton = app.buttons["Settings"]
        if settingsButton.waitForExistence(timeout: 3) {
            settingsButton.tap()
            sleep(1)
            return true
        }

        // Fallback: try static texts
        let settingsText = app.staticTexts["Settings"]
        if settingsText.waitForExistence(timeout: 2) {
            settingsText.tap()
            sleep(1)
            return true
        }

        return false
    }

    /// Navigate to a tab by name, supporting both iPhone tab bar and iPad floating tab bar.
    private func navigateToTab(_ tabName: String) {
        // Try standard tab bar first
        let tabBarButton = app.tabBars.buttons[tabName]
        if tabBarButton.waitForExistence(timeout: 2) {
            tabBarButton.tap()
            sleep(1)
            return
        }

        // Fallback: try finding button by label (for iPad floating tab bar)
        let button = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", tabName)).firstMatch
        if button.waitForExistence(timeout: 2) {
            button.tap()
            sleep(1)
            return
        }

        // Last resort: try any element with the tab name
        let anyElement = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", tabName)).firstMatch
        if anyElement.waitForExistence(timeout: 2) {
            anyElement.tap()
            sleep(1)
        }
    }
}
