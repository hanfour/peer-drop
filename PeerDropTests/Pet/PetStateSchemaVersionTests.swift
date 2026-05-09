import XCTest
@testable import PeerDrop

/// Pins the schemaVersion contract added in v5.0:
///   • newly-created pets carry schemaVersion = currentSchemaVersion (2)
///   • legacy JSON without the key decodes as schemaVersion = 1
///   • round-trip preserves the value
///
/// Why this matters: without an explicit schema marker, future migrations
/// have to infer the source version from field-shape heuristics. The
/// marker is cheap and unblocks clean v5 → v6 migrations.
final class PetStateSchemaVersionTests: XCTestCase {

    func test_newPet_carriesCurrentSchemaVersion() {
        let pet = PetState.newEgg()
        XCTAssertEqual(pet.schemaVersion, PetState.currentSchemaVersion)
        XCTAssertEqual(PetState.currentSchemaVersion, 2,
                       "v5.0 sets currentSchemaVersion to 2")
    }

    func test_encodedPet_includesSchemaVersionField() throws {
        let pet = PetState.newEgg()
        let data = try JSONEncoder().encode(pet)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["schemaVersion"] as? Int, 2)
    }

    func test_legacyJSON_withoutSchemaVersion_decodesAsVersion1() throws {
        // Simulate a v3.x / v4.x pet whose JSON predates schemaVersion field
        let pet = PetState.newEgg()
        let data = try JSONEncoder().encode(pet)
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json.removeValue(forKey: "schemaVersion")
        let strippedData = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(PetState.self, from: strippedData)

        XCTAssertEqual(decoded.schemaVersion, 1,
                       "missing schemaVersion key → legacy v1 JSON")
    }

    func test_codableRoundTrip_preservesSchemaVersion() throws {
        var pet = PetState.newEgg()
        pet.schemaVersion = 99  // arbitrary; check round-trip
        let data = try JSONEncoder().encode(pet)
        let decoded = try JSONDecoder().decode(PetState.self, from: data)
        XCTAssertEqual(decoded.schemaVersion, 99)
    }

    func test_currentSchemaVersion_isStableConstant() {
        // Sanity: `currentSchemaVersion` must not be accidentally mutable.
        // If this test fails the constant moved without intent.
        XCTAssertEqual(PetState.currentSchemaVersion, 2)
    }
}
