import XCTest

final class ConsentFlowUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    func testAppLaunches() {
        // Verify the main view loads
        XCTAssertTrue(app.navigationBars["PeerDrop"].exists)
    }

    func testManualConnectButtonExists() {
        let button = app.buttons["Connect by IP Address"]
        XCTAssertTrue(button.exists)
    }

    func testManualConnectSheetAppears() {
        app.buttons["Connect by IP Address"].tap()

        // Verify the manual connect sheet appears
        let navBar = app.navigationBars["Manual Connect"]
        XCTAssertTrue(navBar.waitForExistence(timeout: 2))
    }

    func testManualConnectCanCancel() {
        app.buttons["Connect by IP Address"].tap()

        let cancelButton = app.buttons["Cancel"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 2))
        cancelButton.tap()

        // Sheet should dismiss
        let navBar = app.navigationBars["Manual Connect"]
        XCTAssertFalse(navBar.exists)
    }
}
