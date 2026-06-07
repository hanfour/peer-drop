//
//  MacSnapshotTestsDark.swift
//  PeerDropMacUITests
//
//  Dark-mode variant of MacSnapshotTests. Flips NSApplication.appearance
//  via the standard launch-arg approach (NSRequiresAquaSystemAppearance
//  doesn't apply; instead we rely on Snapfile passing
//  `-AppleInterfaceStyle Dark` or the host system being in dark mode at
//  capture time — fastlane snapshot doesn't have a built-in toggle on
//  macOS, so the SnapfileMac runs the suite once per appearance).
//
//  Each test name has the same root + `_Dark` suffix so fastlane saves
//  them in parallel under the same lang directory.

import XCTest

@MainActor
final class MacSnapshotTestsDark: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false

        app = XCUIApplication()
        setupSnapshot(app)

        app.launchArguments += ["-SCREENSHOT_MODE", "1"]
        // -AppleInterfaceStyle Dark forces the dark variant per
        // NSAppearance defaults. Used by SnapfileMac when capturing
        // the dark suite.
        app.launchArguments += ["-AppleInterfaceStyle", "Dark"]

        app.launch()
        sleep(2)
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func test01_Nearby_Dark() {
        snapshot("01_Nearby_Dark")
    }

    func test02_Trusted_Dark() {
        let trusted = app.outlines.staticTexts["Trusted"]
        if trusted.waitForExistence(timeout: 3) {
            trusted.click()
        }
        sleep(1)
        snapshot("02_Trusted_Dark")
    }

    func test03_Relay_Dark() {
        let relay = app.outlines.staticTexts["Relay"]
        if relay.waitForExistence(timeout: 3) {
            relay.click()
        }
        sleep(1)
        snapshot("03_Relay_Dark")
    }

    func test04_Pet_Dark() {
        let pet = app.outlines.staticTexts["Pet"]
        if pet.waitForExistence(timeout: 3) {
            pet.click()
        }
        sleep(1)
        snapshot("04_Pet_Dark")
    }

    func test05_Settings_Dark() {
        app.typeKey(",", modifierFlags: .command)
        sleep(2)
        snapshot("05_Settings_Dark")
    }
}
