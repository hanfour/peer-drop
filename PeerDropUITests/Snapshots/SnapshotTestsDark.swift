//
//  SnapshotTestsDark.swift
//  PeerDropUITests
//
//  Dark mode screenshot tests for App Store submission.
//  Run with: fastlane screenshots
//

import XCTest

/// Dark mode screenshot tests for Fastlane snapshot.
/// Captures all screens in Dark Mode for App Store display.
final class SnapshotTestsDark: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false

        app = XCUIApplication()
        setupSnapshot(app)

        // Enable screenshot mode via launch argument
        app.launchArguments += ["-SCREENSHOT_MODE", "1"]

        // Force Dark Mode
        app.launchArguments += ["-UIUserInterfaceStyle", "Dark"]

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

    // MARK: - Dark Mode Screenshot Tests

    /// 01: Nearby tab with discovered devices (list view)
    func test01_NearbyTab_Dark() {
        // Wait for app to fully load
        sleep(3)

        // Wait for navigation bar to appear (works on both iPhone and iPad)
        let nearbyTitle = app.navigationBars["PeerDrop"]
        _ = nearbyTitle.waitForExistence(timeout: 8)

        snapshot("01_NearbyTab_Dark")
    }

    /// 02: Nearby tab in grid view mode
    func test02_NearbyTabGrid_Dark() {
        let gridButton = app.buttons["grid-toggle-button"]
        if gridButton.waitForExistence(timeout: 3) {
            gridButton.tap()
        }

        sleep(1)
        snapshot("02_NearbyTabGrid_Dark")
    }

    /// 03: Connected tab showing active connections and contacts
    func test03_ConnectedTab_Dark() {
        setupMockConnection()

        navigateToTab("Connected")
        sleep(1)

        let connectedTitle = app.navigationBars["Connected"]
        XCTAssertTrue(connectedTitle.waitForExistence(timeout: 5))

        snapshot("03_ConnectedTab_Dark")
    }

    /// 04: Connection detail view with peer info and action buttons
    func test04_ConnectionView_Dark() {
        setupMockConnection()

        _ = navigateToConnectionView()

        let chatButton = app.buttons["chat-button"]
        _ = chatButton.waitForExistence(timeout: 5)

        sleep(1)
        snapshot("04_ConnectionView_Dark")
    }

    /// 05: Chat view with conversation
    func test05_ChatView_Dark() {
        setupMockConnection()

        _ = navigateToConnectionView()

        let chatButton = app.buttons["chat-button"]
        if chatButton.waitForExistence(timeout: 5) {
            chatButton.tap()
        }

        sleep(3)

        snapshot("05_ChatView_Dark")
    }

    /// 06: Voice call view (in-call UI)
    func test06_VoiceCallView_Dark() {
        setupMockConnection()

        _ = navigateToConnectionView()

        let voiceButton = app.buttons["voice-call-button"]
        if voiceButton.waitForExistence(timeout: 5) {
            voiceButton.tap()
        }

        sleep(2)
        snapshot("06_VoiceCallView_Dark")
    }

    /// 07: Library tab with device groups and history
    func test07_LibraryTab_Dark() {
        navigateToTab("Library")
        sleep(1)

        let libraryTitle = app.navigationBars["Library"]
        XCTAssertTrue(libraryTitle.waitForExistence(timeout: 5))

        snapshot("07_LibraryTab_Dark")
    }

    /// 08: Settings screen
    func test08_Settings_Dark() {
        navigateToTab("Nearby")
        sleep(1)

        let menuOpened = openSettingsMenu()

        if menuOpened {
            sleep(1)
            snapshot("08_Settings_Dark")
        } else {
            snapshot("08_Settings_Dark_Fallback")
        }
    }

    /// 09: Quick Connect (Manual Connect) sheet
    func test09_QuickConnect_Dark() {
        navigateToTab("Nearby")
        sleep(1)

        let quickConnect = app.buttons["quick-connect-button"]

        if quickConnect.waitForExistence(timeout: 3) {
            quickConnect.tap()
        }

        sleep(1)

        let manualConnectNavBar = app.navigationBars["Manual Connect"]
        if manualConnectNavBar.waitForExistence(timeout: 3) {
            snapshot("09_QuickConnect_Dark")
        } else {
            snapshot("09_QuickConnect_Dark_Fallback")
        }

        let cancelButton = app.buttons["Cancel"]
        if cancelButton.exists {
            cancelButton.tap()
        }
    }

    /// 10: File transfer progress
    func test10_FileTransfer_Dark() {
        setupMockConnection()

        _ = navigateToConnectionView()

        let sendFileButton = app.buttons["send-file-button"]
        if sendFileButton.waitForExistence(timeout: 5) {
            sendFileButton.tap()
        }

        sleep(1)
        snapshot("10_FileTransfer_Dark")

        let cancelButton = app.buttons["Cancel"]
        if cancelButton.exists {
            cancelButton.tap()
        }
    }

    // MARK: - Helper Methods

    private func setupMockConnection() {
        sleep(2)

        navigateToTab("Connected")

        let activePeerRow = app.buttons.matching(NSPredicate(format: "identifier == 'active-peer-row'")).firstMatch
        let connected = activePeerRow.waitForExistence(timeout: 5)

        if !connected {
            let connectedText = app.staticTexts["Connected"]
            _ = connectedText.waitForExistence(timeout: 3)
        }

        navigateToTab("Nearby")
        sleep(1)
    }

    private func navigateToConnectionView() -> Bool {
        navigateToTab("Connected")
        sleep(1)

        let activePeerRow = app.buttons.matching(NSPredicate(format: "identifier == 'active-peer-row'")).firstMatch
        guard activePeerRow.waitForExistence(timeout: 5) else {
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

        let chatButton = app.buttons["chat-button"]
        let sendFileButton = app.buttons["send-file-button"]

        for _ in 0..<10 {
            if chatButton.exists || sendFileButton.exists {
                return true
            }
            usleep(500_000)
        }

        return true
    }

    private func openSettingsMenu() -> Bool {
        let menuButton = app.buttons["more-options-menu"]
        if menuButton.waitForExistence(timeout: 3) {
            menuButton.tap()
            sleep(1)
        } else {
            let navBar = app.navigationBars["PeerDrop"]
            let buttons = navBar.buttons
            if buttons.count > 0 {
                buttons.element(boundBy: buttons.count - 1).tap()
                sleep(1)
            } else {
                return false
            }
        }

        let settingsButton = app.buttons["Settings"]
        if settingsButton.waitForExistence(timeout: 3) {
            settingsButton.tap()
            sleep(1)
            return true
        }

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
