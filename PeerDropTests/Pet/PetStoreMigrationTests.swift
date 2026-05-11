import XCTest
@testable import PeerDrop

/// Verifies the M7.2 first-launch migration sweep:
///   • legacy v3.x pets get subVariety, seed, and migrationDoneAt assigned
///   • subVariety derives from BodyGene.defaultSpeciesID.variant
///   • seed is deterministic from (petID, name) — same input on any device
///     produces the same seed (so cloud-sync re-migration is stable)
///   • single-variety legacy bodies (.octopus) leave subVariety nil
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
        // nil and "" intentionally hash identically (both map to "" before
        // concat). Pets without names are rare and the collision is harmless.
        let id = UUID()
        XCTAssertEqual(
            PetStore.deterministicSeed(petID: id, petName: nil),
            PetStore.deterministicSeed(petID: id, petName: nil))
        XCTAssertEqual(
            PetStore.deterministicSeed(petID: id, petName: nil),
            PetStore.deterministicSeed(petID: id, petName: ""),
            "nil and empty string are intentionally equivalent — see deterministicSeed docstring")
    }

    func test_deterministicSeed_normalisesUnicodeNames() {
        // "café" can be encoded as composed (U+00E9) or decomposed
        // (U+0065 U+0301). FNV operates on UTF-8 bytes which differ between
        // the two forms — the production code normalises to NFC first so
        // both forms produce the same seed.
        let id = UUID()
        let composed   = "caf\u{00E9}"           // é as one code point
        let decomposed = "cafe\u{0301}"          // e + combining acute
        XCTAssertNotEqual(composed.unicodeScalars.count,
                          decomposed.unicodeScalars.count,
                          "test setup sanity: forms must differ at the scalar level")
        XCTAssertEqual(
            PetStore.deterministicSeed(petID: id, petName: composed),
            PetStore.deterministicSeed(petID: id, petName: decomposed),
            "different Unicode normalisation forms must hash to the same seed")
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

    func test_applyV4Migration_alreadyMigrated_earlyReturns() {
        // When migrationDoneAt is set, the function early-returns regardless
        // of the other fields — verifies the gate, not field-level merge.
        var pet = PetState.newEgg()
        pet.genome.body = .cat
        pet.genome.subVariety = nil
        pet.genome.seed = nil
        let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
        pet.migrationDoneAt = originalDate

        let migrated = PetStore.applyV4Migration(to: pet)
        // Early-return contract: nothing is modified, even nil fields.
        XCTAssertNil(migrated.genome.subVariety)
        XCTAssertNil(migrated.genome.seed)
        XCTAssertEqual(migrated.migrationDoneAt, originalDate)
    }

    func test_applyV4Migration_pinnedSubVariety_isNotOverwritten() {
        // When migrationDoneAt is nil but subVariety is already set (e.g.
        // user picked one explicitly before the migration sweep got a chance
        // to run), the migration must respect the existing pin and only fill
        // in genuinely missing fields. Tighter than the "early-return" test
        // above — this exercises the per-field guards inside applyV4Migration.
        var pet = PetState.newEgg()
        pet.genome.body = .cat                   // would map to "tabby" by default
        pet.genome.subVariety = "persian"        // user pin
        pet.genome.seed = nil
        pet.migrationDoneAt = nil

        let migrated = PetStore.applyV4Migration(to: pet)
        XCTAssertEqual(migrated.genome.subVariety, "persian",
                       "user pin must survive migration")
        XCTAssertNotNil(migrated.genome.seed, "missing seed should be filled in")
        XCTAssertNotNil(migrated.migrationDoneAt, "migrationDoneAt should now be set")
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

    // MARK: - cloud-load migration mirror

    func test_petCloudSync_appliesV4Migration_viaPureFunction() {
        // PetCloudSync.loadAndMigrateFromCloud delegates to the same pure
        // function as PetStore.loadAndMigrate. We can't easily exercise the
        // iCloud container in unit tests, but we can verify the migration
        // function is the canonical entry — same outcome whether the source
        // is local file or cloud doc.
        var legacy = PetState.newEgg()
        legacy.genome.body = .cat
        legacy.genome.subVariety = nil
        legacy.genome.seed = nil
        legacy.migrationDoneAt = nil

        let migrated = PetStore.applyV4Migration(to: legacy)
        XCTAssertEqual(migrated.genome.subVariety, "tabby")
        XCTAssertNotNil(migrated.genome.seed)
        XCTAssertNotNil(migrated.migrationDoneAt)
        // Every storage layer (local file, iCloud doc, peer payload) should
        // funnel through this single function rather than duplicating the
        // assignment logic.
    }

    func test_loadAndMigrate_setsEggMigratedFlag_whenLevelOneOnDisk() throws {
        // Phase 5: when the v3.x JSON had level=1 (.egg), loadAndMigrate must
        // set the v4MigratedFromEgg UserDefaults flag so V4UpgradeOnboarding
        // can show "your egg has hatched into a ..." copy. The PetLevel
        // decoder silently maps rawValue 1 → .baby, so we peek at the JSON
        // before Codable swallows the signal.
        let suiteName = "PetStoreMigrationTests-eggFlag-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.removeObject(forKey: "v4MigratedFromEgg")

        let v3xEggJSON = """
        {
          "id": "66666666-6666-6666-6666-666666666666",
          "name": "Eggy",
          "birthDate": 740000000,
          "level": 1,
          "experience": 0,
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
        try v3xEggJSON.write(to: tempDir.appendingPathComponent("pet.json"))

        let migrated = try store.loadAndMigrate(defaults: defaults)
        XCTAssertEqual(migrated?.level, .baby, "level=1 should decode to .baby (Phase 1 decoder)")
        XCTAssertTrue(
            defaults.bool(forKey: "v4MigratedFromEgg"),
            "loadAndMigrate must set v4MigratedFromEgg flag when source JSON had level=1")
    }

    func test_loadAndMigrate_doesNotSetEggMigratedFlag_whenLevelHigher() throws {
        // Sanity inverse: a v3.x pet that was already past egg (level >= 2)
        // should NOT trigger the egg-hatched flag. Confirms we're peeking at
        // the field, not unconditionally setting it.
        let suiteName = "PetStoreMigrationTests-eggFlag-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.removeObject(forKey: "v4MigratedFromEgg")

        let v3xJSON = """
        {
          "id": "77777777-7777-7777-7777-777777777777",
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

        _ = try store.loadAndMigrate(defaults: defaults)
        XCTAssertFalse(
            defaults.bool(forKey: "v4MigratedFromEgg"),
            "loadAndMigrate must not set v4MigratedFromEgg when source JSON level != 1")
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
