import XCTest

/// Verify the 4 new features: Online/Offline toggle, Connectivity, Notifications, Archive.
final class FeatureVerificationTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += ["-peerDropIsOnline", "YES"]
        app.launch()

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5))
    }

    // MARK: - Feature 1: Online/Offline Toggle

    func testOnlineOfflineToggle() {
        let navBar = app.navigationBars["PeerDrop"]
        XCTAssertTrue(navBar.waitForExistence(timeout: 3), "Navigation bar should exist")

        // Look for the antenna button by accessibility label
        let onlineButton = navBar.buttons["Go offline"]
        let offlineButton = navBar.buttons["Go online"]

        if onlineButton.exists {
            // Screenshot online state
            let ss1 = app.screenshot()
            let a1 = XCTAttachment(screenshot: ss1)
            a1.name = "F1-online-state"
            a1.lifetime = .keepAlways
            add(a1)

            // Tap to go offline
            onlineButton.tap()
            sleep(1)

            // Verify offline UI
            let offlineText = app.staticTexts["You are offline"]
            XCTAssertTrue(offlineText.waitForExistence(timeout: 3), "Should show 'You are offline'")

            let goOnlineBtn = app.buttons["Go Online"]
            XCTAssertTrue(goOnlineBtn.exists, "Should show 'Go Online' button")

            let ss2 = app.screenshot()
            let a2 = XCTAttachment(screenshot: ss2)
            a2.name = "F1-offline-state"
            a2.lifetime = .keepAlways
            add(a2)

            // Restore online
            goOnlineBtn.tap()
            sleep(1)
        } else if offlineButton.exists {
            offlineButton.tap()
            sleep(1)
        } else {
            XCTFail("Neither Go offline nor Go online button found")
        }
    }

    // MARK: - Features 2, 3, 4: Settings Sections

    func testSettingsNewSections() {
        let navBar = app.navigationBars["PeerDrop"]
        XCTAssertTrue(navBar.waitForExistence(timeout: 3))

        // Open the "..." menu — try accessibility identifier first
        let menuButton = navBar.buttons["ellipsis.circle"]
        if menuButton.exists {
            menuButton.tap()
        } else {
            // Fall back: tap the last button in the nav bar trailing group
            let allButtons = navBar.buttons.allElementsBoundByIndex
            guard let last = allButtons.last else {
                XCTFail("No buttons in nav bar")
                return
            }
            last.tap()
        }
        sleep(1)

        // Tap Settings
        let settingsItem = app.buttons["Settings"]
        guard settingsItem.waitForExistence(timeout: 3) else {
            XCTFail("Settings menu item not found")
            return
        }
        settingsItem.tap()
        sleep(1)

        // Screenshot top of Settings
        let ss1 = app.screenshot()
        let a1 = XCTAttachment(screenshot: ss1)
        a1.name = "F2-settings-connectivity"
        a1.lifetime = .keepAlways
        add(a1)

        // Feature 2: Connectivity toggles
        XCTAssertTrue(app.switches["File Transfer"].exists, "File Transfer toggle should exist")
        XCTAssertTrue(app.switches["Voice Calls"].exists, "Voice Calls toggle should exist")
        XCTAssertTrue(app.switches["Chat"].exists, "Chat toggle should exist")

        // Feature 3: Notifications toggle
        XCTAssertTrue(app.switches["Enable Notifications"].exists, "Notifications toggle should exist")

        // Scroll down for Archive section
        app.swipeUp()
        sleep(1)

        let ss2 = app.screenshot()
        let a2 = XCTAttachment(screenshot: ss2)
        a2.name = "F4-settings-archive"
        a2.lifetime = .keepAlways
        add(a2)

        // Feature 4: Archive buttons
        let exportBtn = app.buttons["Export Archive"]
        let importBtn = app.buttons["Import Archive"]
        XCTAssertTrue(exportBtn.exists, "Export Archive button should exist")
        XCTAssertTrue(importBtn.exists, "Import Archive button should exist")
    }
}
