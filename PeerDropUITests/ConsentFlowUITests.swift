import XCTest

final class ConsentFlowUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Labels asserted below are English; pin the locale so the result doesn't depend on the simulator language.
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        // Wait for tab bar to appear
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5))
    }

    func testAppLaunches() {
        XCTAssertTrue(app.tabBars.firstMatch.exists)
        XCTAssertTrue(app.tabBars.buttons["Nearby"].exists)
        XCTAssertTrue(app.tabBars.buttons["Home"].exists)
        XCTAssertTrue(app.tabBars.buttons["Notes"].exists)
        XCTAssertTrue(app.tabBars.buttons["Diaries"].exists)
    }

    /// Home is the default tab since the four-tab overhaul (was Nearby/Notes).
    func testHomeTabIsDefault() {
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 3))
    }

    func testTabsNavigateThroughAllFour() {
        for name in ["Notes", "Nearby", "Diaries", "Home"] {
            app.tabBars.buttons[name].tap()
            XCTAssertTrue(app.tabBars.buttons[name].isSelected, "\(name) tab should be selected")
        }
    }

    func testQuickConnectOpensManualConnect() {
        app.tabBars.buttons["Nearby"].tap()
        let quickConnect = app.buttons["quick-connect-button"]
        XCTAssertTrue(quickConnect.waitForExistence(timeout: 3))
        quickConnect.tap()

        let navBar = app.navigationBars["Manual Connect"]
        XCTAssertTrue(navBar.waitForExistence(timeout: 3))
    }

    func testManualConnectCanCancel() {
        app.tabBars.buttons["Nearby"].tap()
        let quickConnect = app.buttons["quick-connect-button"]
        XCTAssertTrue(quickConnect.waitForExistence(timeout: 3))
        quickConnect.tap()

        let cancelButton = app.buttons["Cancel"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 3))
        cancelButton.tap()

        let navBar = app.navigationBars["Manual Connect"]
        let dismissed = navBar.waitForNonExistence(timeout: 3)
        XCTAssertTrue(dismissed)
    }

    func testSwitchToHomeTab() {
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 3))
    }
}
