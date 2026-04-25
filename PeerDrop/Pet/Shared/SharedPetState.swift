import Foundation

struct PetSnapshot: Codable, Equatable {
    let name: String?
    let bodyType: BodyGene
    let eyeType: EyeGene
    let patternType: PatternGene
    let level: PetLevel
    let mood: PetMood
    let paletteIndex: Int
    let experience: Int
    let maxExperience: Int
}

/// Bridge between the main app and the widget / Live Activity.
///
/// Writes the latest pet snapshot to a file inside the App Group container
/// using NSFileCoordinator. Coordinated reads/writes prevent the widget
/// process from observing a half-written file (the previous UserDefaults
/// implementation could race mid-encode and silently produce nil decodes).
class SharedPetState {
    static let appGroupID = "group.com.hanfour.peerdrop"
    private static let filename = "pet-snapshot.json"
    /// Legacy UserDefaults key used by v3.3.x and earlier. Migrated on first
    /// init when the new file does not yet exist.
    private static let legacyDefaultsKey = "petSnapshot"

    private let containerURL: URL

    init(suiteName: String? = appGroupID) {
        if let suite = suiteName,
           let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suite) {
            self.containerURL = url
        } else {
            // Fallback for tests / non-app-group context: use a per-process
            // temp dir so concurrent test cases don't clobber each other.
            self.containerURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("SharedPetState", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: containerURL, withIntermediateDirectories: true)
        }
        migrateLegacyUserDefaultsIfNeeded(suiteName: suiteName)
    }

    private var fileURL: URL { containerURL.appendingPathComponent(Self.filename) }

    func write(_ snapshot: PetSnapshot) {
        let data: Data
        do {
            data = try JSONEncoder().encode(snapshot)
        } catch {
            assertionFailure("Failed to encode PetSnapshot: \(error)")
            return
        }

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinatorError: NSError?
        coordinator.coordinate(
            writingItemAt: fileURL, options: .forReplacing,
            error: &coordinatorError
        ) { url in
            // .atomic ensures the file is written to a temp location and
            // renamed into place — readers never see a half-written file.
            try? data.write(to: url, options: .atomic)
        }
    }

    func read() -> PetSnapshot? {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinatorError: NSError?
        var result: PetSnapshot?
        coordinator.coordinate(
            readingItemAt: fileURL, options: [],
            error: &coordinatorError
        ) { url in
            guard let data = try? Data(contentsOf: url) else { return }
            result = try? JSONDecoder().decode(PetSnapshot.self, from: data)
        }
        return result
    }

    func clear() {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinatorError: NSError?
        coordinator.coordinate(
            writingItemAt: fileURL, options: .forDeleting,
            error: &coordinatorError
        ) { url in
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Migration

    private func migrateLegacyUserDefaultsIfNeeded(suiteName: String?) {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        guard let suite = suiteName,
              let defaults = UserDefaults(suiteName: suite),
              let legacyData = defaults.data(forKey: Self.legacyDefaultsKey)
        else { return }
        // Validate the legacy blob before promoting it — we never want to
        // surface a corrupt snapshot to the widget.
        guard (try? JSONDecoder().decode(PetSnapshot.self, from: legacyData)) != nil
        else {
            defaults.removeObject(forKey: Self.legacyDefaultsKey)
            return
        }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinatorError: NSError?
        coordinator.coordinate(
            writingItemAt: fileURL, options: .forReplacing,
            error: &coordinatorError
        ) { url in
            try? legacyData.write(to: url, options: .atomic)
        }
        defaults.removeObject(forKey: Self.legacyDefaultsKey)
    }
}
