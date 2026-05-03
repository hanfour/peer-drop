import Foundation
import os

private let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "PetCloudSync")

class PetCloudSync {
    private let kvStore = NSUbiquitousKeyValueStore.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var cloudDirectory: URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents/PetData")
    }

    /// Sync lightweight metadata via iCloud KVS.
    func syncMetadata(_ pet: PetState) {
        kvStore.set(pet.id.uuidString, forKey: "pet_id")
        kvStore.set(Int64(pet.level.rawValue), forKey: "pet_level")
        kvStore.set(Int64(pet.experience), forKey: "pet_exp")
        kvStore.synchronize()
        logger.debug("Synced metadata for pet \(pet.id)")
    }

    /// Sync full pet state to iCloud Documents.
    func syncFullState(_ pet: PetState) throws {
        guard let dir = cloudDirectory else {
            logger.warning("iCloud container not available — skipping full sync")
            return
        }
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let fileURL = dir.appendingPathComponent("pet.json")
        let data = try encoder.encode(pet)
        try data.write(to: fileURL, options: .atomic)
        logger.debug("Synced full state to iCloud for pet \(pet.id)")
    }

    /// Load pet state from iCloud Documents. Raw decode — does NOT apply
    /// the v4.0 migration sweep. Prefer `loadAndMigrateFromCloud()` unless
    /// you specifically need the unmigrated cloud state for inspection or
    /// conflict resolution.
    func loadFromCloud() throws -> PetState? {
        guard let dir = cloudDirectory else {
            logger.warning("iCloud container not available — cannot load from cloud")
            return nil
        }
        let fileURL = dir.appendingPathComponent("pet.json")
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: fileURL)
        let pet = try decoder.decode(PetState.self, from: data)
        logger.debug("Loaded pet \(pet.id) from iCloud")
        return pet
    }

    /// Load + migrate. Mirrors PetStore.loadAndMigrate but in-memory only —
    /// PetCloudSync doesn't write back here because the cloud file is owned
    /// by the most-recent saver across all devices on the iCloud account;
    /// blindly re-saving a migrated copy could clobber a concurrent peer's
    /// write. The next local save() will persist the migration.
    func loadAndMigrateFromCloud() throws -> PetState? {
        guard let pet = try loadFromCloud() else { return nil }
        return PetStore.applyV4Migration(to: pet)
    }

    /// Resolve conflict between local and cloud state. Higher XP wins.
    func resolveConflict(local: PetState, cloud: PetState) -> PetState {
        let winner = local.experience >= cloud.experience ? local : cloud
        logger.debug("Conflict resolved: winner has \(winner.experience) XP")
        return winner
    }

    /// Observe iCloud KVS changes and notify via callback. Loads + migrates
    /// the cloud state before forwarding so a v3.x cloud record (or one from
    /// a v4.0 device that hasn't yet run loadAndMigrate) doesn't surface as
    /// an unmigrated pet in the UI.
    func observeCloudChanges(onUpdate: @escaping (PetState) -> Void) {
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvStore,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            do {
                if let pet = try self.loadAndMigrateFromCloud() {
                    onUpdate(pet)
                }
            } catch {
                logger.error("Failed to load cloud pet on change: \(error.localizedDescription)")
            }
        }
    }
}
