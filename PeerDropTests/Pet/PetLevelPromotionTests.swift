import XCTest
@testable import PeerDrop

@MainActor
final class PetLevelPromotionTests: XCTestCase {

    // MARK: - baby → adult @ 8 days

    func test_baby_promotesToAdult_at8DaysFromBirth() {
        var pet = PetState.newEgg()
        pet.level = .baby
        pet.genome.body = .cat
        pet.birthDate = Date().addingTimeInterval(-(8 * 86400 + 1))  // 8 days + 1 second ago
        let engine = PetEngine(pet: pet)
        engine.handleInteraction(.tap)
        XCTAssertEqual(engine.pet.level, .adult)
    }

    func test_baby_doesNotPromote_at7DaysFromBirth() {
        var pet = PetState.newEgg()
        pet.level = .baby
        pet.genome.body = .cat
        pet.birthDate = Date().addingTimeInterval(-(7 * 86400))
        let engine = PetEngine(pet: pet)
        engine.handleInteraction(.tap)
        XCTAssertEqual(engine.pet.level, .baby)
    }

    // MARK: - adult → elder @ 90 days + recent activity (v5)

    func test_adult_promotesToElder_at90DaysWithRecentInteraction() {
        // v5: adult→elder requires age >= 90 days AND lastInteraction within
        // 30 days. handleInteraction itself updates lastInteraction to now,
        // so this test naturally satisfies the activity gate.
        var pet = PetState.newEgg()
        pet.level = .adult
        pet.genome.body = .cat
        pet.birthDate = Date().addingTimeInterval(-(90 * 86400 + 1))
        let engine = PetEngine(pet: pet)
        engine.handleInteraction(.tap)
        XCTAssertEqual(engine.pet.level, .elder)
    }

    func test_adult_doesNotPromote_at89DaysFromBirth() {
        var pet = PetState.newEgg()
        pet.level = .adult
        pet.genome.body = .cat
        pet.birthDate = Date().addingTimeInterval(-(89 * 86400))
        let engine = PetEngine(pet: pet)
        engine.handleInteraction(.tap)
        XCTAssertEqual(engine.pet.level, .adult)
    }

    func test_adult_doesNotPromote_at14DaysFromBirth_underV5() {
        // Regression test for the user-reported v4.0.x bug ("all pets are
        // turning old"). Pre-v5: 14 days = elder. v5: still adult.
        var pet = PetState.newEgg()
        pet.level = .adult
        pet.genome.body = .cat
        pet.birthDate = Date().addingTimeInterval(-(14 * 86400 + 1))
        let engine = PetEngine(pet: pet)
        engine.handleInteraction(.tap)
        XCTAssertEqual(engine.pet.level, .adult,
                       "v5 must NOT promote to elder at 14 days like v4.0.x did")
    }

    // MARK: - activity gate (covered indirectly via migrateAgingForV5 below;
    // direct test on checkEvolution is tricky because every interaction
    // path also updates lastInteraction = now, so an "inactive at adult"
    // scenario would need to bypass interaction tracking entirely.)

    // MARK: - elder is terminal

    func test_elder_remainsElder_evenAfter200Days() {
        var pet = PetState.newEgg()
        pet.level = .elder
        pet.genome.body = .cat
        pet.birthDate = Date().addingTimeInterval(-(200 * 86400))
        let engine = PetEngine(pet: pet)
        engine.handleInteraction(.tap)
        XCTAssertEqual(engine.pet.level, .elder)
    }

    // MARK: - migrateAgingForV5

    func test_migrateAgingForV5_demotesIncorrectElder() {
        // The user-reported scenario: a pet that was promoted to elder under
        // v4.0.x's 14-day gate but doesn't qualify under v5. After migration,
        // it should be back to adult.
        var pet = PetState.newEgg()
        pet.level = .elder
        pet.genome.body = .cat
        pet.birthDate = Date().addingTimeInterval(-(20 * 86400))  // 20 days = was elder under v4
        pet.lastInteraction = Date()
        let engine = PetEngine(pet: pet)

        let demoted = engine.migrateAgingForV5()

        XCTAssertTrue(demoted, "v4 elder at 20d should demote")
        XCTAssertEqual(engine.pet.level, .adult)
    }

    func test_migrateAgingForV5_keepsLegitimateElder() {
        // Pet that legitimately qualifies under v5 (90+ days, active) stays.
        var pet = PetState.newEgg()
        pet.level = .elder
        pet.genome.body = .cat
        pet.birthDate = Date().addingTimeInterval(-(120 * 86400))  // 120 days
        pet.lastInteraction = Date().addingTimeInterval(-(5 * 86400))  // 5 days ago, active
        let engine = PetEngine(pet: pet)

        let demoted = engine.migrateAgingForV5()

        XCTAssertFalse(demoted)
        XCTAssertEqual(engine.pet.level, .elder)
    }

    func test_migrateAgingForV5_demotesInactiveElder() {
        // Pet old enough (90+ days) but inactive >30 days — should demote
        // because the v5 contract is "elder requires ongoing engagement".
        var pet = PetState.newEgg()
        pet.level = .elder
        pet.genome.body = .cat
        pet.birthDate = Date().addingTimeInterval(-(120 * 86400))
        pet.lastInteraction = Date().addingTimeInterval(-(45 * 86400))  // 45 days ago
        let engine = PetEngine(pet: pet)

        let demoted = engine.migrateAgingForV5()

        XCTAssertTrue(demoted)
        XCTAssertEqual(engine.pet.level, .adult)
    }

    func test_migrateAgingForV5_isIdempotent() {
        // Re-running the migration on an already-correct pet is a no-op.
        var pet = PetState.newEgg()
        pet.level = .adult
        pet.genome.body = .cat
        pet.birthDate = Date().addingTimeInterval(-(20 * 86400))
        let engine = PetEngine(pet: pet)

        let firstRun = engine.migrateAgingForV5()
        let secondRun = engine.migrateAgingForV5()

        XCTAssertFalse(firstRun, "non-elder pets are no-ops")
        XCTAssertFalse(secondRun)
        XCTAssertEqual(engine.pet.level, .adult)
    }

    // MARK: - PetState.migrationDoneAt field

    func test_newEgg_hasNilMigrationDoneAt() {
        let pet = PetState.newEgg()
        XCTAssertNil(pet.migrationDoneAt)
    }

    func test_migrationDoneAt_codableRoundTrip() throws {
        var pet = PetState.newEgg()
        pet.migrationDoneAt = Date(timeIntervalSince1970: 1_700_000_000)
        let data = try JSONEncoder().encode(pet)
        let decoded = try JSONDecoder().decode(PetState.self, from: data)
        XCTAssertEqual(decoded.migrationDoneAt?.timeIntervalSince1970, 1_700_000_000)
    }

    func test_legacyJSON_missingMigrationDoneAt_decodesAsNil() throws {
        // Simulate a v3.x persisted pet whose JSON has no migrationDoneAt key.
        let pet = PetState.newEgg()
        let data = try JSONEncoder().encode(pet)
        var dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        dict.removeValue(forKey: "migrationDoneAt")
        let strippedData = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(PetState.self, from: strippedData)
        XCTAssertNil(decoded.migrationDoneAt)
    }
}
