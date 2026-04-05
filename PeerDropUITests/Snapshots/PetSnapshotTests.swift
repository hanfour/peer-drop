//
//  PetSnapshotTests.swift
//  PeerDropUITests
//
//  Pet screenshot tests for App Store submission.
//  Run with: fastlane screenshots
//

import XCTest

/// Pet screenshot tests for Fastlane snapshot.
/// Captures pet-related screens using SCREENSHOT_MODE mock data.
@MainActor
final class PetSnapshotTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false

        app = XCUIApplication()
        setupSnapshot(app)

        // Enable screenshot mode via launch argument
        app.launchArguments += ["-SCREENSHOT_MODE", "1"]

        app.launch()

        // Wait for app to fully load
        sleep(5)
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Pet Screenshot Tests

    /// 14: Nearby tab with floating pet visible
    func test14_NearbyWithPet() {
        sleep(3)
        snapshot("14_NearbyWithPet")
    }

    /// 15: Pet interaction panel (long press on pet)
    func test15_PetInteractionPanel() {
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
            snapshot("15_PetInteractionPanel")
        }
    }
}
