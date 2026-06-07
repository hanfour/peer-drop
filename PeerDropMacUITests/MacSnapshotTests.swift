//
//  MacSnapshotTests.swift
//  PeerDropMacUITests
//
//  Automated screenshot tests for Mac App Store submission.
//  Run with: fastlane screenshots_mac
//
//  Mirrors the iOS PeerDropUITests/Snapshots/SnapshotTests pattern but
//  targets the macOS NavigationSplitView sidebar layout. SCREENSHOT_MODE
//  is the same launch argument iOS uses — PeerDropMacApp.onAppear wires
//  it to populate mock peers + Pet state via ScreenshotModeProvider.

import XCTest

@MainActor
final class MacSnapshotTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false

        app = XCUIApplication()
        setupSnapshot(app)

        // SCREENSHOT_MODE: routes ConnectionManager.startDiscovery to
        // mock data and seeds petEngine.pet from
        // ScreenshotModeProvider.mockPetState.
        app.launchArguments += ["-SCREENSHOT_MODE", "1"]

        app.launch()

        // Allow scene + sidebar + Pet sprite + mock peer injection to
        // settle. Mac NavigationSplitView is fast (no waiting for
        // remote data), but the sprite engine has a ~50-200ms first
        // render that we'd rather catch in the screenshot.
        sleep(2)
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Screenshot Tests

    /// 01: Nearby sidebar section with mock discovered peers
    func test01_Nearby() {
        // Sidebar defaults to .nearby on launch (MacContentView.selection).
        snapshot("01_Nearby")
    }

    /// 02: Trusted (Library) sidebar section
    func test02_Trusted() {
        // Sidebar List rows are selectable by their localised label.
        // SCREENSHOT_MODE locale shims keep "Trusted" stable on en-US runs.
        let trusted = app.outlines.staticTexts["Trusted"]
        if trusted.waitForExistence(timeout: 3) {
            trusted.click()
        }
        sleep(1)
        snapshot("02_Trusted")
    }

    /// 03: Relay sidebar section
    func test03_Relay() {
        let relay = app.outlines.staticTexts["Relay"]
        if relay.waitForExistence(timeout: 3) {
            relay.click()
        }
        sleep(1)
        snapshot("03_Relay")
    }

    /// 04: Pet sidebar section — 256pt sprite rendered live
    func test04_Pet() {
        let pet = app.outlines.staticTexts["Pet"]
        if pet.waitForExistence(timeout: 3) {
            pet.click()
        }
        // Pet first-render race: wait extra ~200ms beyond the setUp
        // delay so the CGImage is published before the snapshot fires.
        sleep(1)
        snapshot("04_Pet")
    }

    /// 05: Settings (Preferences) scene
    func test05_Settings() {
        // ⌘, opens the Settings scene per the standard macOS shortcut.
        // PeerDropMacApp wires it to MacSettingsView (tabbed).
        app.typeKey(",", modifierFlags: .command)
        sleep(2)
        snapshot("05_Settings")
    }
}
