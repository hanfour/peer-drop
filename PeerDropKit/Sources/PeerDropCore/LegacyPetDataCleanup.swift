import Foundation
import os

/// Abstraction over `NSUbiquitousKeyValueStore` so the cleanup is testable
/// without an iCloud entitlement.
public protocol LegacyPetKeyValueStore: AnyObject {
    func removeObject(forKey aKey: String)
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: LegacyPetKeyValueStore {}

/// One-shot removal of everything the retired pet system (v3–v5.6) left on
/// the device and in the user's iCloud. Runs once per install (marker in
/// `UserDefaults`), best-effort: a failure on one location is logged and the
/// others still run. Product pivot 2026-09 — see
/// docs/superpowers/specs/2026-09-14-notes-diary-pivot-design.md §6.
public struct LegacyPetDataCleanup {

    /// Set to `true` in `defaults` after the first successful pass.
    public static let markerKey = "legacyPetDataCleanupDone_v6"

    /// `UserDefaults.standard` keys written by the pet UI / migrations.
    public static let standardDefaultsKeys = [
        "renderedImageVersion",
        "hasSeenPetWelcome_v4",
        "v4UpgradeShown",
        "v4MigratedFromEgg",
        "v5UpgradeShown",
    ]

    /// `NSUbiquitousKeyValueStore` keys written by `PetCloudSync.syncMetadata`.
    public static let kvStoreKeys = ["pet_id", "pet_level", "pet_exp"]

    /// Legacy widget bridge key in the app-group `UserDefaults` suite.
    public static let appGroupDefaultsKey = "petSnapshot"

    /// Widget bridge files in the app-group container.
    public static let appGroupFiles = ["pet-snapshot.json", "pet-rendered.png"]

    private static let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "LegacyPetDataCleanup")

    let documentsDirectory: URL
    let appGroupContainer: URL?
    let ubiquityContainer: URL?
    let defaults: UserDefaults
    let appGroupDefaults: UserDefaults?
    let kvStore: LegacyPetKeyValueStore?
    let fileManager: FileManager

    public init(
        documentsDirectory: URL,
        appGroupContainer: URL?,
        ubiquityContainer: URL?,
        defaults: UserDefaults,
        appGroupDefaults: UserDefaults?,
        kvStore: LegacyPetKeyValueStore?,
        fileManager: FileManager = .default
    ) {
        self.documentsDirectory = documentsDirectory
        self.appGroupContainer = appGroupContainer
        self.ubiquityContainer = ubiquityContainer
        self.defaults = defaults
        self.appGroupDefaults = appGroupDefaults
        self.kvStore = kvStore
        self.fileManager = fileManager
    }

    /// Runs `run()` unless the marker is already set. Returns `true` when the
    /// cleanup executed in this call.
    @discardableResult
    public func runIfNeeded() -> Bool {
        guard !defaults.bool(forKey: Self.markerKey) else { return false }
        run()
        defaults.set(true, forKey: Self.markerKey)
        return true
    }

    /// Unconditional cleanup of every known location.
    public func run() {
        removeItem(documentsDirectory.appendingPathComponent("PetData"))

        if let group = appGroupContainer {
            for name in Self.appGroupFiles {
                removeItem(group.appendingPathComponent(name))
            }
        }
        appGroupDefaults?.removeObject(forKey: Self.appGroupDefaultsKey)

        if let cloud = ubiquityContainer {
            removeItem(cloud.appendingPathComponent("Documents/PetData"))
        }

        for key in Self.standardDefaultsKeys {
            defaults.removeObject(forKey: key)
        }

        if let kv = kvStore {
            for key in Self.kvStoreKeys {
                kv.removeObject(forKey: key)
            }
            kv.synchronize()
        }
        Self.logger.info("Legacy pet data cleanup completed")
    }

    private func removeItem(_ url: URL) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            Self.logger.error("Failed to remove \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Production wiring. Resolving the ubiquity container can block, so the
    /// whole pass runs on a detached background task.
    public static func runInBackgroundIfNeeded(appGroupSuite: String = "group.com.hanfour.peerdrop") {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: markerKey) else { return }
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let cleanup = LegacyPetDataCleanup(
                documentsDirectory: docs,
                appGroupContainer: fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupSuite),
                ubiquityContainer: fm.url(forUbiquityContainerIdentifier: nil),
                defaults: defaults,
                appGroupDefaults: UserDefaults(suiteName: appGroupSuite),
                kvStore: NSUbiquitousKeyValueStore.default
            )
            cleanup.runIfNeeded()
        }
    }
}
