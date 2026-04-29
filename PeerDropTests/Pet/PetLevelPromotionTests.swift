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

    // MARK: - adult → elder @ 14 days

    func test_adult_promotesToElder_at14DaysFromBirth() {
        var pet = PetState.newEgg()
        pet.level = .adult
        pet.genome.body = .cat
        pet.birthDate = Date().addingTimeInterval(-(14 * 86400 + 1))
        let engine = PetEngine(pet: pet)
        engine.handleInteraction(.tap)
        XCTAssertEqual(engine.pet.level, .elder)
    }

    func test_adult_doesNotPromote_at13DaysFromBirth() {
        var pet = PetState.newEgg()
        pet.level = .adult
        pet.genome.body = .cat
        pet.birthDate = Date().addingTimeInterval(-(13 * 86400))
        let engine = PetEngine(pet: pet)
        engine.handleInteraction(.tap)
        XCTAssertEqual(engine.pet.level, .adult)
    }

    // MARK: - elder is terminal

    func test_elder_remainsElder_evenAfter100Days() {
        var pet = PetState.newEgg()
        pet.level = .elder
        pet.genome.body = .cat
        pet.birthDate = Date().addingTimeInterval(-(100 * 86400))
        let engine = PetEngine(pet: pet)
        engine.handleInteraction(.tap)
        XCTAssertEqual(engine.pet.level, .elder)
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
