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
}
