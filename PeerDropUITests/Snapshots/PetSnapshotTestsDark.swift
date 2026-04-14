//
//  PetSnapshotTestsDark.swift
//  PeerDropUITests
//
//  Dark mode pet screenshot tests for App Store submission.
//

import XCTest

/// Dark mode pet screenshot tests for Fastlane snapshot.
@MainActor
final class PetSnapshotTestsDark: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false

        app = XCUIApplication()
        setupSnapshot(app)

        app.launchArguments += ["-SCREENSHOT_MODE", "1"]
        app.launchArguments += ["-UIUserInterfaceStyle", "Dark"]

        app.launch()
        sleep(8)
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func test14_NearbyWithPet_Dark() {
        sleep(3)
        let tabBar = app.tabBars.firstMatch
        if tabBar.exists {
            let nearbyTab = tabBar.buttons.element(boundBy: 0)
            if nearbyTab.exists { nearbyTab.tap() }
        }
        sleep(2)
        snapshot("14_NearbyWithPet_Dark")
    }

    func test15_PetInteractionPanel_Dark() {
        sleep(3)

        let pet = app.otherElements["floating-pet"]
        if pet.waitForExistence(timeout: 5) {
            pet.press(forDuration: 2.0)
            sleep(2)
        } else {
            let positions: [CGVector] = [
                CGVector(dx: 0.08, dy: 0.22),
                CGVector(dx: 0.15, dy: 0.25),
                CGVector(dx: 0.08, dy: 0.30),
            ]
            for pos in positions {
                let coord = app.windows.firstMatch.coordinate(withNormalizedOffset: pos)
                coord.press(forDuration: 2.0)
                sleep(1)
                if app.navigationBars.matching(NSPredicate(format: "identifier CONTAINS[c] 'pet' OR identifier CONTAINS[c] '寵物'")).firstMatch.exists {
                    break
                }
            }
        }

        let panelShown = app.navigationBars["我的寵物"].waitForExistence(timeout: 3) ||
                          app.navigationBars["My Pet"].waitForExistence(timeout: 1) ||
                          app.navigationBars["マイペット"].waitForExistence(timeout: 1) ||
                          app.navigationBars["내 펫"].waitForExistence(timeout: 1) ||
                          app.navigationBars["我的宠物"].waitForExistence(timeout: 1)

        if panelShown {
            snapshot("15_PetInteractionPanel_Dark")
        } else {
            snapshot("15_PetInteractionPanel_Dark_Fallback")
        }
    }

    func test16_PetTab_Dark() {
        sleep(2)
        let tabBar = app.tabBars.firstMatch
        if tabBar.exists {
            let petTab = tabBar.buttons.element(boundBy: 3)
            if petTab.exists { petTab.tap() }
        }
        sleep(2)
        snapshot("16_PetTab_Dark")
    }
}
