import XCTest

final class ConsentFlowUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()

        // Wait for launch screen to dismiss and main UI to appear
        let navBar = app.navigationBars["PeerDrop"]
        XCTAssertTrue(navBar.waitForExistence(timeout: 5))
    }

    func testAppLaunches() {
        XCTAssertTrue(app.navigationBars["PeerDrop"].exists)
    }

    func testManualConnectButtonExists() {
        let button = app.buttons["Connect by IP Address"]
        XCTAssertTrue(button.waitForExistence(timeout: 3))
    }

    func testManualConnectSheetAppears() {
        let button = app.buttons["Connect by IP Address"]
        XCTAssertTrue(button.waitForExistence(timeout: 3))
        button.tap()

        let navBar = app.navigationBars["Manual Connect"]
        XCTAssertTrue(navBar.waitForExistence(timeout: 3))
    }

    func testManualConnectCanCancel() {
        let connectButton = app.buttons["Connect by IP Address"]
        XCTAssertTrue(connectButton.waitForExistence(timeout: 3))
        connectButton.tap()

        let cancelButton = app.buttons["Cancel"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 3))
        cancelButton.tap()

        // Sheet should dismiss — wait briefly for animation
        let navBar = app.navigationBars["Manual Connect"]
        let dismissed = navBar.waitForNonExistence(timeout: 3)
        XCTAssertTrue(dismissed)
    }
}
