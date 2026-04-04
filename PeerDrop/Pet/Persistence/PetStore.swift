import Foundation
import os

private let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "PetStore")

class PetStore {
    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Default: Documents/PetData/
    /// Accepts custom directory for testing.
    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            self.directory = docs.appendingPathComponent("PetData")
        }
    }

    private var petFile: URL { directory.appendingPathComponent("pet.json") }
    private var snapshotsDir: URL { directory.appendingPathComponent("snapshots") }

    /// Encode and write the pet state to petFile.
    func save(_ pet: PetState) throws {
        try ensureDirectory(directory)
        let data = try encoder.encode(pet)
        try data.write(to: petFile, options: .atomic)
        logger.debug("Saved pet \(pet.id) at level \(pet.level.rawValue)")
    }

    /// Load pet state from petFile. Returns nil if file doesn't exist.
    func load() throws -> PetState? {
        guard FileManager.default.fileExists(atPath: petFile.path) else {
            return nil
        }
        let data = try Data(contentsOf: petFile)
        let pet = try decoder.decode(PetState.self, from: data)
        logger.debug("Loaded pet \(pet.id) at level \(pet.level.rawValue)")
        return pet
    }

    /// Save an evolution snapshot to snapshots/lv{N}_{bodyGene}.json.
    func saveEvolutionSnapshot(_ pet: PetState) throws {
        try ensureDirectory(snapshotsDir)
        let filename = "lv\(pet.level.rawValue)_\(pet.genome.body.rawValue).json"
        let fileURL = snapshotsDir.appendingPathComponent(filename)
        let data = try encoder.encode(pet)
        try data.write(to: fileURL, options: .atomic)
        logger.debug("Saved evolution snapshot: \(filename)")
    }

    /// Load all evolution snapshots.
    func loadSnapshots() throws -> [PetState] {
        guard FileManager.default.fileExists(atPath: snapshotsDir.path) else {
            return []
        }
        let files = try FileManager.default.contentsOfDirectory(
            at: snapshotsDir,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }

        return try files.compactMap { url in
            let data = try Data(contentsOf: url)
            return try decoder.decode(PetState.self, from: data)
        }
    }

    /// Remove entire directory (for testing cleanup).
    func deleteAll() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.path) {
            try fm.removeItem(at: directory)
            logger.debug("Deleted PetStore directory")
        }
    }

    private func ensureDirectory(_ dir: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
