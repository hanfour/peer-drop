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

    // MARK: - v4.0 first-launch migration

    /// Loads pet state and applies the v4.0 first-launch migration sweep
    /// if the stored record is from v3.x (lacks `migrationDoneAt`). The
    /// migrated state is persisted before being returned. Idempotent — once
    /// `migrationDoneAt` is set, subsequent calls return the stored state
    /// without re-running the sweep.
    func loadAndMigrate() throws -> PetState? {
        guard let pet = try load() else { return nil }
        let migrated = PetStore.applyV4Migration(to: pet)
        if migrated.migrationDoneAt != pet.migrationDoneAt {
            try save(migrated)
        }
        return migrated
    }

    /// Pure migration function. Idempotent: pets that already carry
    /// `migrationDoneAt` are returned unchanged. For legacy v3.x pets:
    ///   • subVariety ← BodyGene.defaultSpeciesID.variant if nil (legacy
    ///     single-variety bodies like .octopus get nil — defaultSpeciesID is
    ///     bare and has no variant token)
    ///   • seed ← deterministicSeed(petID, name) if nil — same input on any
    ///     device produces the same seed, so cloud-sync re-migration is stable
    ///   • migrationDoneAt ← now()
    static func applyV4Migration(to pet: PetState) -> PetState {
        guard pet.migrationDoneAt == nil else { return pet }
        var p = pet
        if p.genome.subVariety == nil,
           let variant = p.genome.body.defaultSpeciesID.variant {
            p.genome.subVariety = variant
        }
        if p.genome.seed == nil {
            p.genome.seed = deterministicSeed(petID: p.id, petName: p.name)
        }
        p.migrationDoneAt = Date()
        return p
    }

    /// Stable 32-bit hash of (petID, name). Uses FNV-1a so the result is
    /// deterministic across processes and devices — important because cloud
    /// sync may re-run migration on a different device for the same pet,
    /// and we want both devices to land on the same seed (otherwise their
    /// seed-derived sub-variety picks would diverge).
    static func deterministicSeed(petID: UUID, petName: String?) -> UInt32 {
        let key = "\(petID.uuidString)|\(petName ?? "")"
        var hash: UInt32 = 2_166_136_261   // FNV-1a 32-bit offset basis
        for byte in key.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619     // FNV prime
        }
        return hash
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
