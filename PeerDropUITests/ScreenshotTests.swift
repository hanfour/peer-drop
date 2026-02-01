import XCTest

/// Automated screenshot tests that capture every reachable screen in the simulator.
final class ScreenshotTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()

        let navBar = app.navigationBars["PeerDrop"]
        XCTAssertTrue(navBar.waitForExistence(timeout: 5))
    }

    /// Capture the main discovery screen.
    func testCaptureDiscoveryScreen() {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "01-discovery"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Verify UI elements
        XCTAssertTrue(app.navigationBars["PeerDrop"].exists)
        XCTAssertTrue(app.staticTexts["Nearby Devices"].exists)
        XCTAssertTrue(app.staticTexts["Tailscale / Manual"].exists)
        XCTAssertTrue(app.buttons["Connect by IP Address"].exists)
    }

    /// Capture the settings screen.
    func testCaptureSettingsScreen() {
        // Tap settings gear
        let settingsButton = app.buttons["Settings"]
        if settingsButton.waitForExistence(timeout: 3) {
            settingsButton.tap()
        } else {
            // Try by accessibility identifier or image
            let gearButton = app.navigationBars.buttons.element(boundBy: 0)
            if gearButton.exists {
                gearButton.tap()
            }
        }

        sleep(1)
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "02-settings"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Capture the manual connect sheet.
    func testCaptureManualConnectSheet() {
        let button = app.buttons["Connect by IP Address"]
        XCTAssertTrue(button.waitForExistence(timeout: 3))
        button.tap()

        let navBar = app.navigationBars["Manual Connect"]
        XCTAssertTrue(navBar.waitForExistence(timeout: 3))

        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "03-manual-connect"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Verify form elements exist
        XCTAssertTrue(app.buttons["Cancel"].exists)
    }

    /// Capture manual connect, fill in IP, then cancel.
    func testCaptureManualConnectFilled() {
        let button = app.buttons["Connect by IP Address"]
        XCTAssertTrue(button.waitForExistence(timeout: 3))
        button.tap()

        let navBar = app.navigationBars["Manual Connect"]
        XCTAssertTrue(navBar.waitForExistence(timeout: 3))

        // Try to find and fill the host text field
        let textFields = app.textFields
        if textFields.count > 0 {
            let hostField = textFields.element(boundBy: 0)
            hostField.tap()
            hostField.typeText("100.64.0.5")
        }

        sleep(1)
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "04-manual-connect-filled"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Cancel
        app.buttons["Cancel"].tap()
    }
}
