import XCTest

/// Automated screenshot tests that capture every reachable screen in the simulator.
final class ScreenshotTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5))
    }

    /// Capture the Nearby tab (default).
    func testCaptureNearbyTab() {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "01-nearby-tab"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertTrue(app.navigationBars["PeerDrop"].exists)
    }

    /// Capture the Connected tab.
    func testCaptureConnectedTab() {
        app.tabBars.buttons["Connected"].tap()
        sleep(1)

        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "02-connected-tab"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertTrue(app.navigationBars["Connected"].exists)
    }

    /// Capture the Library tab.
    func testCaptureLibraryTab() {
        app.tabBars.buttons["Library"].tap()
        sleep(1)

        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "03-library-tab"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertTrue(app.navigationBars["Library"].exists)
    }

    /// Capture the Quick Connect (manual connect) sheet.
    func testCaptureQuickConnect() {
        let quickConnect = app.buttons["Quick Connect"]
        XCTAssertTrue(quickConnect.waitForExistence(timeout: 3))
        quickConnect.tap()

        let navBar = app.navigationBars["Manual Connect"]
        XCTAssertTrue(navBar.waitForExistence(timeout: 3))

        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "04-quick-connect"
        attachment.lifetime = .keepAlways
        add(attachment)

        app.buttons["Cancel"].tap()
    }

    /// Navigate to Settings via the toolbar menu.
    private func navigateToSettings() -> Bool {
        // The ellipsis.circle is a Menu in SwiftUI — try multiple query strategies
        let menuButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'ellipsis' OR identifier CONTAINS[c] 'ellipsis'")).firstMatch
        if menuButton.waitForExistence(timeout: 3) {
            menuButton.tap()
            sleep(1)
        } else {
            // Fallback: tap the last button in the navigation bar (the menu is rightmost)
            let navBar = app.navigationBars["PeerDrop"]
            let buttons = navBar.buttons
            if buttons.count > 0 {
                buttons.element(boundBy: buttons.count - 1).tap()
                sleep(1)
            }
        }

        // In the menu popup, find and tap Settings
        let settingsButton = app.buttons["Settings"]
        if settingsButton.waitForExistence(timeout: 3) {
            settingsButton.tap()
            sleep(1)
            return true
        }
        // Try as menu item / static text
        let settingsText = app.staticTexts["Settings"]
        if settingsText.waitForExistence(timeout: 2) {
            settingsText.tap()
            sleep(1)
            return true
        }
        return false
    }

    /// Capture the Settings screen (opened via ellipsis menu on Nearby tab).
    func testCaptureSettings() {
        let opened = navigateToSettings()
        guard opened else {
            // Take screenshot anyway to see current state
            let fallback = XCTAttachment(screenshot: app.screenshot())
            fallback.name = "05-settings-fallback"
            fallback.lifetime = .keepAlways
            add(fallback)
            return
        }

        sleep(1)
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "05-settings"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Scroll down to see more settings
        app.swipeUp()
        sleep(1)

        let screenshot2 = app.screenshot()
        let attachment2 = XCTAttachment(screenshot: screenshot2)
        attachment2.name = "06-settings-bottom"
        attachment2.lifetime = .keepAlways
        add(attachment2)
    }

    /// Capture the User Profile screen (via Settings > Profile).
    func testCaptureUserProfile() {
        let opened = navigateToSettings()
        guard opened else {
            let fallback = XCTAttachment(screenshot: app.screenshot())
            fallback.name = "07-profile-fallback"
            fallback.lifetime = .keepAlways
            add(fallback)
            return
        }

        sleep(1)

        // Tap the Profile NavigationLink button (not the section header)
        let profileButton = app.buttons["Profile"]
        XCTAssertTrue(profileButton.waitForExistence(timeout: 3))
        profileButton.tap()
        sleep(1)

        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "07-user-profile"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
