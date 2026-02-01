import XCTest

final class ConsentFlowUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()

        // Wait for tab bar to appear
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5))
    }

    func testAppLaunches() {
        XCTAssertTrue(app.tabBars.firstMatch.exists)
        XCTAssertTrue(app.tabBars.buttons["Nearby"].exists)
        XCTAssertTrue(app.tabBars.buttons["Connected"].exists)
        XCTAssertTrue(app.tabBars.buttons["Library"].exists)
    }

    func testNearbyTabIsDefault() {
        XCTAssertTrue(app.navigationBars["PeerDrop"].waitForExistence(timeout: 3))
    }

    func testQuickConnectOpensManualConnect() {
        let quickConnect = app.buttons["Quick Connect"]
        XCTAssertTrue(quickConnect.waitForExistence(timeout: 3))
        quickConnect.tap()

        let navBar = app.navigationBars["Manual Connect"]
        XCTAssertTrue(navBar.waitForExistence(timeout: 3))
    }

    func testManualConnectCanCancel() {
        let quickConnect = app.buttons["Quick Connect"]
        XCTAssertTrue(quickConnect.waitForExistence(timeout: 3))
        quickConnect.tap()

        let cancelButton = app.buttons["Cancel"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 3))
        cancelButton.tap()

        let navBar = app.navigationBars["Manual Connect"]
        let dismissed = navBar.waitForNonExistence(timeout: 3)
        XCTAssertTrue(dismissed)
    }

    func testSwitchToConnectedTab() {
        app.tabBars.buttons["Connected"].tap()
        XCTAssertTrue(app.navigationBars["Connected"].waitForExistence(timeout: 3))
    }

    func testSwitchToLibraryTab() {
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 3))
    }
}
