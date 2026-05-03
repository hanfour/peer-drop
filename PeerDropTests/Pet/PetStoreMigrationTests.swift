import XCTest
@testable import PeerDrop

/// Verifies the M7.2 first-launch migration sweep:
///   • legacy v3.x pets get subVariety, seed, and migrationDoneAt assigned
///   • subVariety derives from BodyGene.defaultSpeciesID.variant
///   • seed is deterministic from (petID, name) — same input on any device
///     produces the same seed (so cloud-sync re-migration is stable)
///   • single-variety legacy bodies (.octopus, .ghost) leave subVariety nil
///   • idempotent: re-loading after migration returns the stored pet
///     unchanged; subsequent calls don't re-run the sweep
final class PetStoreMigrationTests: XCTestCase {

    private var tempDir: URL!
    private var store: PetStore!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PetStoreMigrationTests-\(UUID().uuidString)")
        store = PetStore(directory: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - deterministic seed (pure function)

    func test_deterministicSeed_isStable_acrossCalls() {
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let s1 = PetStore.deterministicSeed(petID: id, petName: "Whiskers")
        let s2 = PetStore.deterministicSeed(petID: id, petName: "Whiskers")
        XCTAssertEqual(s1, s2, "same input must produce the same seed every call")
    }

    func test_deterministicSeed_differs_byPetID() {
        let s1 = PetStore.deterministicSeed(
            petID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            petName: "x")
        let s2 = PetStore.deterministicSeed(
            petID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            petName: "x")
        XCTAssertNotEqual(s1, s2)
    }

    func test_deterministicSeed_differs_byName() {
        let id = UUID()
        let s1 = PetStore.deterministicSeed(petID: id, petName: "alpha")
        let s2 = PetStore.deterministicSeed(petID: id, petName: "beta")
        XCTAssertNotEqual(s1, s2)
    }

    func test_deterministicSeed_handlesNilName() {
        // nil name shouldn't crash; should be distinct from a pet named "".
        let id = UUID()
        let s1 = PetStore.deterministicSeed(petID: id, petName: nil)
        let s2 = PetStore.deterministicSeed(petID: id, petName: nil)
        XCTAssertEqual(s1, s2)
    }

    // MARK: - applyV4Migration (pure)

    func test_applyV4Migration_assigns_subVariety_seed_migrationDoneAt() {
        var pet = PetState.newEgg()
        pet.genome.body = .cat
        pet.genome.subVariety = nil
        pet.genome.seed = nil
        pet.migrationDoneAt = nil

        let migrated = PetStore.applyV4Migration(to: pet)
        XCTAssertEqual(migrated.genome.subVariety, "tabby")
        XCTAssertNotNil(migrated.genome.seed)
        XCTAssertNotNil(migrated.migrationDoneAt)
    }

    func test_applyV4Migration_dogPet_pinsToShiba() {
        var pet = PetState.newEgg()
        pet.genome.body = .dog
        pet.genome.subVariety = nil
        let migrated = PetStore.applyV4Migration(to: pet)
        XCTAssertEqual(migrated.genome.subVariety, "shiba")
    }

    func test_applyV4Migration_octopus_leavesSubVarietyNil() {
        // Single-variety legacy family — defaultSpeciesID is bare "octopus"
        // (no variant). Migration shouldn't invent one.
        var pet = PetState.newEgg()
        pet.genome.body = .octopus
        pet.genome.subVariety = nil
        let migrated = PetStore.applyV4Migration(to: pet)
        XCTAssertNil(migrated.genome.subVariety,
                     "single-variety legacy body should not get a fabricated subVariety")
        XCTAssertNotNil(migrated.genome.seed)
        XCTAssertNotNil(migrated.migrationDoneAt)
    }

    func test_applyV4Migration_alreadyMigrated_isNoOp() {
        var pet = PetState.newEgg()
        pet.genome.body = .cat
        pet.genome.subVariety = "persian"     // user/runtime pinned earlier
        pet.genome.seed = 9999
        let originalDate = Date(timeIntervalSince1970: 1700000000)
        pet.migrationDoneAt = originalDate

        let migrated = PetStore.applyV4Migration(to: pet)
        XCTAssertEqual(migrated.genome.subVariety, "persian", "should not overwrite user pin")
        XCTAssertEqual(migrated.genome.seed, 9999)
        XCTAssertEqual(migrated.migrationDoneAt, originalDate, "should not bump migrationDoneAt")
    }

    func test_applyV4Migration_partialState_fillsOnlyMissingFields() {
        // Already has subVariety but missing seed: migration should add seed
        // and migrationDoneAt without overwriting subVariety.
        var pet = PetState.newEgg()
        pet.genome.body = .cat
        pet.genome.subVariety = "siamese"
        pet.genome.seed = nil
        pet.migrationDoneAt = nil

        let migrated = PetStore.applyV4Migration(to: pet)
        XCTAssertEqual(migrated.genome.subVariety, "siamese")
        XCTAssertNotNil(migrated.genome.seed)
        XCTAssertNotNil(migrated.migrationDoneAt)
    }

    // MARK: - loadAndMigrate (I/O wrapper)

    func test_loadAndMigrate_persistsTheMigration() throws {
        var legacy = PetState.newEgg()
        legacy.genome.body = .cat
        legacy.genome.subVariety = nil
        legacy.genome.seed = nil
        legacy.migrationDoneAt = nil
        try store.save(legacy)

        let loaded = try store.loadAndMigrate()
        XCTAssertNotNil(loaded?.migrationDoneAt)
        XCTAssertEqual(loaded?.genome.subVariety, "tabby")

        // Re-load via plain `load()` — the migration should have been
        // persisted, not just applied in-memory.
        let reloaded = try store.load()
        XCTAssertEqual(reloaded?.migrationDoneAt, loaded?.migrationDoneAt)
        XCTAssertEqual(reloaded?.genome.subVariety, "tabby")
    }

    func test_loadAndMigrate_isIdempotent_acrossCalls() throws {
        var legacy = PetState.newEgg()
        legacy.genome.body = .cat
        legacy.genome.subVariety = nil
        legacy.genome.seed = nil
        legacy.migrationDoneAt = nil
        try store.save(legacy)

        let first = try store.loadAndMigrate()!
        let second = try store.loadAndMigrate()!
        let third = try store.loadAndMigrate()!
        XCTAssertEqual(first.migrationDoneAt, second.migrationDoneAt)
        XCTAssertEqual(second.migrationDoneAt, third.migrationDoneAt)
        XCTAssertEqual(first.genome.seed, second.genome.seed)
    }

    func test_loadAndMigrate_returnsNil_whenNoSavedPet() throws {
        // Empty directory — no saved pet, nothing to migrate.
        let loaded = try store.loadAndMigrate()
        XCTAssertNil(loaded)
    }

    func test_loadAndMigrate_v3xJSON_onDisk_decodesAndMigrates() throws {
        // Simulates a real v3.x → v4.0 upgrade: the saved file is in v3.x
        // shape (no subVariety/seed/migrationDoneAt). loadAndMigrate must
        // decode (via M2.4/M1.2 optional fallback), migrate, persist.
        let v3xJSON = """
        {
          "id": "55555555-5555-5555-5555-555555555555",
          "name": "Tom",
          "birthDate": 740000000,
          "level": 3,
          "experience": 100,
          "genome": { "body": "cat", "eyes": "dot", "pattern": "none", "personalityGene": 0.3 },
          "mood": "happy",
          "socialLog": [],
          "lastInteraction": 740000000,
          "foodInventory": { "items": [] },
          "lifeState": "idle",
          "stats": {
            "foodsEaten": 0, "poopsCleaned": 0, "totalInteractions": 0, "petsMet": 0
          }
        }
        """.data(using: .utf8)!
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try v3xJSON.write(to: tempDir.appendingPathComponent("pet.json"))

        let migrated = try store.loadAndMigrate()
        XCTAssertNotNil(migrated?.migrationDoneAt)
        XCTAssertEqual(migrated?.genome.subVariety, "tabby")
        XCTAssertNotNil(migrated?.genome.seed)
        XCTAssertEqual(migrated?.level, .adult)
    }
}
