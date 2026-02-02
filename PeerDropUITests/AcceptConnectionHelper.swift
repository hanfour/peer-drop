import XCTest

/// Helper test that waits for an incoming connection consent sheet and accepts it.
/// Run this on Sim 1 while initiating a connection from Sim 2.
final class AcceptConnectionHelper: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5))
    }

    func testAcceptIncomingConnection() {
        // Wait for consent sheet with Accept button (up to 30 seconds)
        let acceptButton = app.buttons["Accept"]
        guard acceptButton.waitForExistence(timeout: 30) else {
            XCTFail("No incoming connection consent sheet appeared within 30 seconds")
            return
        }

        // Tap Accept
        acceptButton.tap()

        // Verify we transition to Connected tab
        let connectedNav = app.navigationBars["Connected"]
        XCTAssertTrue(connectedNav.waitForExistence(timeout: 5), "Should auto-switch to Connected tab after accepting")

        // Stay connected for a while to allow feature testing from the other device
        sleep(30)
    }
}
