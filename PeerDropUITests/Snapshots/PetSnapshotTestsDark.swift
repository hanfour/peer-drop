//
//  PetSnapshotTestsDark.swift
//  PeerDropUITests
//
//  Dark mode pet screenshot tests for App Store submission.
//  Run with: fastlane screenshots
//

import XCTest

/// Dark mode pet screenshot tests for Fastlane snapshot.
/// Captures pet-related screens in Dark Mode.
@MainActor
final class PetSnapshotTestsDark: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false

        app = XCUIApplication()
        setupSnapshot(app)

        // Enable screenshot mode via launch argument
        app.launchArguments += ["-SCREENSHOT_MODE", "1"]

        // Force Dark Mode
        app.launchArguments += ["-UIUserInterfaceStyle", "Dark"]

        app.launch()

        // Wait for app to fully load
        sleep(5)
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Dark Mode Pet Screenshot Tests

    /// 14: Nearby tab with floating pet visible (dark mode)
    func test14_NearbyWithPet_Dark() {
        sleep(3)
        snapshot("14_NearbyWithPet_Dark")
    }

    /// 15: Pet interaction panel (long press on pet, dark mode)
    func test15_PetInteractionPanel_Dark() {
        sleep(3)

        // The floating pet should be visible as an overlay
        // Since pet is a Canvas, use coordinate-based tap
        let petArea = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.25))
        petArea.press(forDuration: 1.5)
        sleep(2)

        // Check if the interaction sheet appeared
        if app.navigationBars["我的寵物"].waitForExistence(timeout: 3) ||
           app.navigationBars["My Pet"].waitForExistence(timeout: 1) ||
           app.navigationBars["マイペット"].waitForExistence(timeout: 1) {
            snapshot("15_PetInteractionPanel_Dark")
        }
    }
}
