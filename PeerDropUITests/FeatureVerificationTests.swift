import XCTest

/// Quick verification test to screenshot all 4 new features.
final class FeatureVerificationTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5))
    }

    func testFeature1_ConnectionStatusHeader() {
        // Feature 1: Connection status header should be visible on Nearby tab
        sleep(1)
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "F1-connection-header-nearby"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Check for "Not Connected" text in the toolbar area
        let notConnected = app.staticTexts["Not Connected"]
        XCTAssertTrue(notConnected.exists, "Connection status header should show 'Not Connected'")
    }

    func testFeature2_LibraryGroups() {
        // Feature 2: Library tab with groups
        app.tabBars.buttons["Library"].tap()
        sleep(1)

        let screenshot1 = app.screenshot()
        let attachment1 = XCTAttachment(screenshot: screenshot1)
        attachment1.name = "F2-library-tab"
        attachment1.lifetime = .keepAlways
        add(attachment1)

        // Check for group management button
        let groupButton = app.buttons["folder.badge.gearshape"]
        if groupButton.waitForExistence(timeout: 2) {
            groupButton.tap()
            sleep(1)

            let screenshot2 = app.screenshot()
            let attachment2 = XCTAttachment(screenshot: screenshot2)
            attachment2.name = "F2-library-group-menu"
            attachment2.lifetime = .keepAlways
            add(attachment2)

            // Tap "New Group" if visible
            let newGroup = app.buttons["New Group"]
            if newGroup.waitForExistence(timeout: 2) {
                newGroup.tap()
                sleep(1)

                let screenshot3 = app.screenshot()
                let attachment3 = XCTAttachment(screenshot: screenshot3)
                attachment3.name = "F2-group-editor"
                attachment3.lifetime = .keepAlways
                add(attachment3)

                // Dismiss
                if app.buttons["Cancel"].exists {
                    app.buttons["Cancel"].tap()
                }
            }
        }
    }

    func testFeature3_EnhancedSettings() {
        // Feature 3: Enhanced settings
        // Open settings via the ellipsis menu on Nearby tab
        let menu = app.buttons["ellipsis.circle"]
        if menu.waitForExistence(timeout: 3) {
            menu.tap()
            sleep(1)

            let settingsButton = app.buttons["Settings"]
            if settingsButton.waitForExistence(timeout: 2) {
                settingsButton.tap()
                sleep(1)

                let screenshot1 = app.screenshot()
                let attachment1 = XCTAttachment(screenshot: screenshot1)
                attachment1.name = "F3-settings-top"
                attachment1.lifetime = .keepAlways
                add(attachment1)

                // Scroll down to see more settings
                app.swipeUp()
                sleep(1)

                let screenshot2 = app.screenshot()
                let attachment2 = XCTAttachment(screenshot: screenshot2)
                attachment2.name = "F3-settings-bottom"
                attachment2.lifetime = .keepAlways
                add(attachment2)

                // Try to navigate to Backup Records
                let backupLink = app.staticTexts["Backup Records"]
                if backupLink.exists {
                    backupLink.tap()
                    sleep(1)

                    let screenshot3 = app.screenshot()
                    let attachment3 = XCTAttachment(screenshot: screenshot3)
                    attachment3.name = "F3-backup-records"
                    attachment3.lifetime = .keepAlways
                    add(attachment3)

                    app.navigationBars.buttons.firstMatch.tap()
                    sleep(1)
                }

                // Navigate to User Profile
                let profileLink = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Profile'")).firstMatch
                if profileLink.exists {
                    profileLink.tap()
                    sleep(1)

                    let screenshot4 = app.screenshot()
                    let attachment4 = XCTAttachment(screenshot: screenshot4)
                    attachment4.name = "F4-user-profile"
                    attachment4.lifetime = .keepAlways
                    add(attachment4)
                }
            }
        }
    }
}
