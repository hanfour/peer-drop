//
//  SnapshotHelper.swift
//  PeerDropUITests
//
//  Created by Fastlane
//

import Foundation
import XCTest

var deviceLanguage = ""
var locale = ""

func setupSnapshot(_ app: XCUIApplication, waitForAnimations: Bool = true) {
    Snapshot.setupSnapshot(app, waitForAnimations: waitForAnimations)
}

func snapshot(_ name: String, waitForLoadingIndicator: Bool) {
    if waitForLoadingIndicator {
        Snapshot.snapshot(name, timeWaitingForIdle: 20)
    } else {
        Snapshot.snapshot(name, timeWaitingForIdle: 0)
    }
}

func snapshot(_ name: String, timeWaitingForIdle timeout: TimeInterval = 20) {
    Snapshot.snapshot(name, timeWaitingForIdle: timeout)
}

enum Snapshot {
    static var app: XCUIApplication?
    static var waitForAnimations = true
    static var cacheDirectory: URL?
    static var screenshotsDirectory: URL? {
        return cacheDirectory
    }

    static func setupSnapshot(_ app: XCUIApplication, waitForAnimations: Bool = true) {
        Snapshot.app = app
        Snapshot.waitForAnimations = waitForAnimations

        do {
            let cacheDir = try getCacheDirectory()
            Snapshot.cacheDirectory = cacheDir
            setLanguage(app)
            setLocale(app)
            setLaunchArguments(app)
        } catch {
            NSLog("Snapshot: Error setting up snapshot: \(error)")
        }
    }

    static func setLanguage(_ app: XCUIApplication) {
        guard let cacheDirectory = cacheDirectory else { return }
        let path = cacheDirectory.appendingPathComponent("language.txt")

        do {
            let trimCharacterSet = CharacterSet.whitespacesAndNewlines
            deviceLanguage = try String(contentsOf: path, encoding: .utf8).trimmingCharacters(in: trimCharacterSet)
            app.launchArguments += ["-AppleLanguages", "(\(deviceLanguage))"]
        } catch {
            NSLog("Snapshot: Couldn't detect the language file")
        }
    }

    static func setLocale(_ app: XCUIApplication) {
        guard let cacheDirectory = cacheDirectory else { return }
        let path = cacheDirectory.appendingPathComponent("locale.txt")

        do {
            let trimCharacterSet = CharacterSet.whitespacesAndNewlines
            locale = try String(contentsOf: path, encoding: .utf8).trimmingCharacters(in: trimCharacterSet)
        } catch {
            NSLog("Snapshot: Couldn't detect the locale file")
        }
    }

    static func setLaunchArguments(_ app: XCUIApplication) {
        guard let cacheDirectory = cacheDirectory else { return }
        let path = cacheDirectory.appendingPathComponent("snapshot-launch_arguments.txt")

        app.launchArguments += ["-FASTLANE_SNAPSHOT", "YES", "-ui_testing"]

        do {
            let launchArguments = try String(contentsOf: path, encoding: .utf8)
            let regex = try NSRegularExpression(pattern: "(\".+?\"|\\S+)", options: [])
            let matches = regex.matches(in: launchArguments, options: [], range: NSRange(location: 0, length: launchArguments.count))

            let results = matches.map { match -> String in
                (launchArguments as NSString).substring(with: match.range)
            }

            app.launchArguments += results
        } catch {
            NSLog("Snapshot: Couldn't detect the launch_arguments file")
        }
    }

    static func snapshot(_ name: String, timeWaitingForIdle timeout: TimeInterval = 20) {
        if timeout > 0 && waitForAnimations {
            waitForLoadingIndicatorToDisappear(within: timeout)
        }

        NSLog("Snapshot: Taking snapshot '\(name)'")

        guard let app = app else {
            NSLog("Snapshot: app is nil, please call setupSnapshot(app) before taking snapshots")
            return
        }

        sleep(1)

        let screenshot = app.windows.firstMatch.screenshot()
        guard let simulator = ProcessInfo().environment["SIMULATOR_DEVICE_NAME"],
              let cacheDir = cacheDirectory else {
            return
        }

        do {
            let path = cacheDir.appendingPathComponent("\(simulator)-\(name).png")
            try screenshot.pngRepresentation.write(to: path)
        } catch {
            NSLog("Snapshot: Problem writing screenshot '\(name)': \(error)")
        }
    }

    static func waitForLoadingIndicatorToDisappear(within timeout: TimeInterval) {
        guard let app = app else { return }

        let networkLoadingIndicator = app.otherElements.deviceStatusBars.networkLoadingIndicators.element
        let progressBar = app.progressIndicators.element(boundBy: 0)
        let activityIndicator = app.activityIndicators.element(boundBy: 0)

        let startTime = Date()
        while networkLoadingIndicator.exists ||
              progressBar.exists ||
              activityIndicator.exists {
            if Date().timeIntervalSince(startTime) > timeout {
                NSLog("Snapshot: Timed out waiting for loading indicators to disappear")
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    static func getCacheDirectory() throws -> URL {
        let cachePath = "Library/Caches/tools.fastlane"
        let homeDir = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"]!
        return URL(fileURLWithPath: homeDir).appendingPathComponent(cachePath)
    }
}

extension XCUIElementQuery {
    var networkLoadingIndicators: XCUIElementQuery {
        let isNetworkLoadingIndicator = NSPredicate { evaluatedObject, _ in
            guard let element = evaluatedObject as? XCUIElementAttributes else { return false }
            return element.identifier == "network-activity-indicator"
        }
        return matching(isNetworkLoadingIndicator)
    }

    var deviceStatusBars: XCUIElementQuery {
        let isDeviceStatusBar = NSPredicate { evaluatedObject, _ in
            guard let element = evaluatedObject as? XCUIElementAttributes else { return false }
            return element.elementType == .statusBar
        }
        return matching(isDeviceStatusBar)
    }
}
