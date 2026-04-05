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

        // Wait for app to fully load (launch screen dismisses after 1.2s)
        sleep(8)
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Pet Screenshot Tests

    /// 14: Nearby tab with floating pet visible
    func test14_NearbyWithPet() {
        // Pet should be visible as floating overlay on the Nearby tab
        // Wait extra time for pet animation to start
        sleep(3)

        // Navigate to Nearby tab to ensure we're on the right screen
        let tabBar = app.tabBars.firstMatch
        if tabBar.exists {
            let nearbyTab = tabBar.buttons.element(boundBy: 0)
            if nearbyTab.exists { nearbyTab.tap() }
        }
        sleep(2)

        snapshot("14_NearbyWithPet")
    }

    /// 15: Pet interaction panel (long press on pet)
    func test15_PetInteractionPanel() {
        sleep(3)

        // Try to find the pet by accessibility identifier
        let pet = app.otherElements["floating-pet"]
        if pet.waitForExistence(timeout: 5) {
            pet.press(forDuration: 2.0)
            sleep(2)
        } else {
            // Fallback: try multiple coordinate positions where pet might be
            let positions: [CGVector] = [
                CGVector(dx: 0.08, dy: 0.22),  // top-left area (initial position ~60,200)
                CGVector(dx: 0.15, dy: 0.25),
                CGVector(dx: 0.08, dy: 0.30),
            ]
            for pos in positions {
                let coord = app.windows.firstMatch.coordinate(withNormalizedOffset: pos)
                coord.press(forDuration: 2.0)
                sleep(1)
                // Check if sheet appeared
                if app.navigationBars.matching(NSPredicate(format: "identifier CONTAINS[c] 'pet' OR identifier CONTAINS[c] '寵物' OR identifier CONTAINS[c] 'ペット'")).firstMatch.exists {
                    break
                }
            }
        }

        // Verify the interaction panel is showing
        let panelShown = app.navigationBars["我的寵物"].waitForExistence(timeout: 3) ||
                          app.navigationBars["My Pet"].waitForExistence(timeout: 1) ||
                          app.navigationBars["マイペット"].waitForExistence(timeout: 1) ||
                          app.navigationBars["내 펫"].waitForExistence(timeout: 1) ||
                          app.navigationBars["我的宠物"].waitForExistence(timeout: 1)

        if panelShown {
            snapshot("15_PetInteractionPanel")
        } else {
            // Fallback: take screenshot anyway to debug
            snapshot("15_PetInteractionPanel_Fallback")
        }
    }
}
