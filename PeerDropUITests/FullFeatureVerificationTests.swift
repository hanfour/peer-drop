import XCTest

/// Comprehensive feature verification tests — exercises all 4 feature enhancements
/// interactively on the simulator and captures screenshots at each step.
final class FullFeatureVerificationTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5))
    }

    // MARK: - Helpers

    private func screenshot(_ name: String) {
        let s = app.screenshot()
        let a = XCTAttachment(screenshot: s)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func openMenu() {
        let menuButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'ellipsis' OR identifier CONTAINS[c] 'ellipsis'")
        ).firstMatch
        if menuButton.waitForExistence(timeout: 3) {
            menuButton.tap()
        } else {
            let navBar = app.navigationBars["PeerDrop"]
            let buttons = navBar.buttons
            buttons.element(boundBy: buttons.count - 1).tap()
        }
        sleep(1)
    }

    private func openSettings() {
        openMenu()
        let settingsButton = app.buttons["Settings"]
        if settingsButton.waitForExistence(timeout: 3) {
            settingsButton.tap()
        }
        sleep(1)
    }

    // MARK: - Feature 1: Connection Status Header

    func test01_ConnectionStatusHeader() {
        // Verify "Not Connected" header exists on Nearby tab
        // It's rendered as a Button with label containing "Not Connected"
        sleep(2)
        let headerButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Not Connected'")
        ).firstMatch
        let headerText = app.staticTexts["Not Connected"]
        let found = headerButton.waitForExistence(timeout: 5) || headerText.waitForExistence(timeout: 2)
        XCTAssertTrue(found, "Connection status header should show 'Not Connected'")
        screenshot("F1-01-nearby-not-connected")

        // Tap the header — should switch to Connected tab (tab index 1)
        if headerButton.exists {
            headerButton.tap()
            sleep(1)
            // Should now be on Connected tab
            let connectedNav = app.navigationBars["Connected"]
            XCTAssertTrue(connectedNav.waitForExistence(timeout: 3),
                          "Tapping connection header should navigate to Connected tab")
            screenshot("F1-02-connected-via-header-tap")
        }

        // Go back to Nearby tab
        app.tabBars.buttons["Nearby"].tap()
        sleep(1)

        // Verify peer discovery is running (look for searching indicator or peer list)
        let searching = app.staticTexts["Searching for nearby devices..."]
        let peerCount = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES '.*\\\\d+.*'")
        ).count
        XCTAssertTrue(searching.exists || peerCount > 0,
                      "Should show searching state or discovered peers")
        screenshot("F1-03-peer-discovery")
    }

    // MARK: - Feature 2: Library Groups

    func test02_LibraryGroups() {
        // Navigate to Library tab
        app.tabBars.buttons["Library"].tap()
        sleep(1)

        // Verify empty state
        let noDevices = app.staticTexts["No saved devices"]
        if noDevices.exists {
            screenshot("F2-01-library-empty")
        }

        // Open group management menu via toolbar
        let groupMenuButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'group' OR label CONTAINS[c] 'folder' OR label CONTAINS[c] 'gear'")
        ).firstMatch
        if groupMenuButton.waitForExistence(timeout: 3) {
            groupMenuButton.tap()
            sleep(1)
            screenshot("F2-02-group-menu-open")

            // Try to create a new group
            let newGroupButton = app.buttons["New Group"]
            if newGroupButton.waitForExistence(timeout: 2) {
                newGroupButton.tap()
                sleep(1)
                screenshot("F2-03-new-group-sheet")

                // Fill in group name
                let nameField = app.textFields.firstMatch
                if nameField.waitForExistence(timeout: 2) {
                    nameField.tap()
                    nameField.typeText("Test Devices")
                    sleep(1)
                    screenshot("F2-04-group-name-filled")

                    // Save the group
                    let saveButton = app.buttons["Save"]
                    if saveButton.waitForExistence(timeout: 2) {
                        saveButton.tap()
                        sleep(1)
                    }
                }
            }
        }

        // Take final library state
        screenshot("F2-05-library-after-group")

        // Try to create a second group via toolbar
        if groupMenuButton.waitForExistence(timeout: 2) {
            groupMenuButton.tap()
            sleep(1)
            let newGroupButton2 = app.buttons["New Group"]
            if newGroupButton2.waitForExistence(timeout: 2) {
                newGroupButton2.tap()
                sleep(1)
                let nameField2 = app.textFields.firstMatch
                if nameField2.waitForExistence(timeout: 2) {
                    nameField2.tap()
                    nameField2.typeText("Office")
                    let saveButton2 = app.buttons["Save"]
                    if saveButton2.waitForExistence(timeout: 2) {
                        saveButton2.tap()
                        sleep(1)
                    }
                }
            }
        }
        screenshot("F2-06-library-two-groups")
    }

    // MARK: - Feature 3: Enhanced Settings

    func test03_EnhancedSettings() {
        // Open Settings
        openSettings()

        let settingsNav = app.navigationBars["Settings"]
        XCTAssertTrue(settingsNav.waitForExistence(timeout: 5), "Settings should open")
        screenshot("F3-01-settings-top")

        // Test Notifications toggle
        let notifToggle = app.switches["Enable Notifications"]
        if notifToggle.waitForExistence(timeout: 2) {
            let wasBefore = notifToggle.value as? String ?? ""
            notifToggle.switches.firstMatch.tap()
            sleep(1)
            let afterTap = notifToggle.value as? String ?? ""
            // Just verify it's interactive — value may or may not visibly change in test
            screenshot("F3-02-notif-toggled")
            // Toggle back if changed
            if wasBefore != afterTap {
                notifToggle.switches.firstMatch.tap()
                sleep(1)
            }
        }

        // Test Bluetooth toggle
        let btToggle = app.switches["Bluetooth"]
        if btToggle.waitForExistence(timeout: 2) {
            btToggle.switches.firstMatch.tap()
            sleep(1)
            screenshot("F3-03-bt-toggled")
            btToggle.switches.firstMatch.tap()
            sleep(1)
        }

        // Test Wi-Fi toggle
        let wifiToggle = app.switches["Wi-Fi"]
        if wifiToggle.waitForExistence(timeout: 2) {
            wifiToggle.switches.firstMatch.tap()
            sleep(1)
            screenshot("F3-04-wifi-toggled")
            wifiToggle.switches.firstMatch.tap()
            sleep(1)
        }

        // Scroll down to see Archive and Data sections
        app.swipeUp()
        sleep(1)
        screenshot("F3-05-settings-bottom")

        // Verify Export/Import buttons exist
        let exportBtn = app.buttons["Export Records"]
        let importBtn = app.buttons["Import Records"]
        XCTAssertTrue(exportBtn.exists || app.staticTexts["Export Records"].exists,
                      "Export Records should exist")
        XCTAssertTrue(importBtn.exists || app.staticTexts["Import Records"].exists,
                      "Import Records should exist")

        // Navigate to Backup Records
        let backupLink = app.buttons["Backup Records"]
        if !backupLink.exists {
            // Try static text
            let backupText = app.staticTexts["Backup Records"]
            if backupText.waitForExistence(timeout: 2) {
                backupText.tap()
                sleep(1)
                screenshot("F3-06-backup-records")
                app.navigationBars.buttons.firstMatch.tap()
                sleep(1)
            }
        } else {
            backupLink.tap()
            sleep(1)
            screenshot("F3-06-backup-records")
            app.navigationBars.buttons.firstMatch.tap()
            sleep(1)
        }

        // Verify version info — scroll until visible
        let version = app.staticTexts["1.0"]
        for _ in 0..<3 {
            if version.exists { break }
            app.swipeUp()
            sleep(1)
        }
        screenshot("F3-07-version-area")
        // Version may be displayed as LabeledContent which XCUITest sees differently
        let versionLabel = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '1.0'")
        ).firstMatch
        XCTAssertTrue(version.exists || versionLabel.exists,
                      "Version info should be visible somewhere in settings")

        // Dismiss settings
        let doneButton = app.buttons["Done"]
        if doneButton.exists {
            doneButton.tap()
            sleep(1)
        }
    }

    // MARK: - Feature 4: User Profile

    func test04_UserProfile() {
        // Open Settings then Profile
        openSettings()
        sleep(1)

        let profileButton = app.buttons["Profile"]
        XCTAssertTrue(profileButton.waitForExistence(timeout: 3), "Profile link should exist")
        profileButton.tap()
        sleep(1)

        let profileNav = app.navigationBars["Profile"]
        XCTAssertTrue(profileNav.waitForExistence(timeout: 3), "Profile screen should open")
        screenshot("F4-01-profile-initial")

        // Verify avatar is displayed (circle with initials)
        // Verify Change Avatar button
        let changeAvatar = app.buttons["Change Avatar"]
        if !changeAvatar.exists {
            let changeAvatarText = app.staticTexts["Change Avatar"]
            XCTAssertTrue(changeAvatarText.exists, "Change Avatar button should exist")
        }

        // Verify Nickname field shows device name
        let nicknameField = app.textFields.firstMatch
        if nicknameField.waitForExistence(timeout: 2) {
            let currentValue = nicknameField.value as? String ?? ""
            XCTAssertFalse(currentValue.isEmpty, "Nickname should have a default value")

            // Edit nickname
            nicknameField.tap()
            nicknameField.clearAndTypeText("Test User")
            sleep(1)
            screenshot("F4-02-profile-edited")

            // Restore original
            nicknameField.tap()
            nicknameField.clearAndTypeText(currentValue)
            sleep(1)
        }

        // Verify Status shows Offline
        let offlineText = app.staticTexts["Offline"]
        XCTAssertTrue(offlineText.exists, "Status should show Offline when not connected")

        screenshot("F4-03-profile-final")

        // Go back to Settings
        app.navigationBars.buttons.firstMatch.tap()
        sleep(1)

        // Dismiss
        let doneButton = app.buttons["Done"]
        if doneButton.exists {
            doneButton.tap()
        }
    }

    // MARK: - Connection: Initiate + Accept

    /// Full connection test: tap peer, wait for connection or failure.
    /// Run on INITIATOR while the other simulator has PeerDrop open.
    func test05a_InitiateConnection() {
        // Wait longer for peer discovery after fresh app launch
        sleep(5)
        let peerCell = app.cells.firstMatch
        guard peerCell.waitForExistence(timeout: 20) else {
            screenshot("C-01-no-peers-found")
            XCTFail("No discovered peers to tap")
            return
        }
        screenshot("C-01-peer-discovered")
        peerCell.tap()
        screenshot("C-02-after-tap")

        // Wait for connected state (auto-switches to Connected tab)
        let connectedNav = app.navigationBars["Connected"]
        if connectedNav.waitForExistence(timeout: 30) {
            screenshot("C-03-connected")
        } else {
            screenshot("C-03-not-connected")
        }
    }

    /// Accept incoming connection. Run on RESPONDER.
    /// setUp calls app.launch() which restarts the app, so peer must re-discover and re-initiate.
    func test05b_AcceptConnection() {
        // Wait for peer discovery + incoming connection request
        sleep(5)
        let acceptButton = app.buttons["Accept"]
        if acceptButton.waitForExistence(timeout: 60) {
            screenshot("C-04-consent-sheet")
            acceptButton.tap()
            sleep(3)
            screenshot("C-05-after-accept")
        } else {
            screenshot("C-04-no-consent-sheet")
        }
    }

    // MARK: - Feature 1+: Peer Discovery (both simulators see each other)

    func test05_PeerDiscovery() {
        // Wait for peer discovery — the other simulator should appear
        sleep(5)
        screenshot("F5-01-peer-discovery-wait")

        // Check if any peer rows appeared
        let peerList = app.cells
        if peerList.count > 0 {
            screenshot("F5-02-peers-found")
            // Verify the peer count badge
            let nearbyHeader = app.staticTexts["Nearby Devices"]
            XCTAssertTrue(nearbyHeader.exists, "Nearby Devices section header should exist")
        } else {
            // Still searching — that's OK, just document it
            let searching = app.staticTexts["Searching for nearby devices..."]
            if searching.exists {
                screenshot("F5-02-still-searching")
            }
        }

        // Switch between tabs to verify all tabs work
        app.tabBars.buttons["Connected"].tap()
        sleep(1)
        screenshot("F5-03-connected-tab")

        app.tabBars.buttons["Library"].tap()
        sleep(1)
        screenshot("F5-04-library-tab")

        app.tabBars.buttons["Nearby"].tap()
        sleep(1)
        screenshot("F5-05-back-to-nearby")
    }
}

// MARK: - Helper Extension

extension XCUIElement {
    func clearAndTypeText(_ text: String) {
        guard let currentValue = self.value as? String, !currentValue.isEmpty else {
            typeText(text)
            return
        }
        // Select all and delete
        tap()
        press(forDuration: 1.0)
        let selectAll = XCUIApplication().menuItems["Select All"]
        if selectAll.waitForExistence(timeout: 2) {
            selectAll.tap()
        }
        typeText(text)
    }
}
