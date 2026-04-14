import XCTest
@testable import PeerDrop

@MainActor
final class PetActionTests: XCTestCase {

    // MARK: - CaseIterable

    func testCaseIterableConformance() {
        // 32 original + 40 species-specific = 72 total
        XCTAssertEqual(PetAction.allCases.count, 72)
    }

    func testAllCasesAreUnique() {
        let rawValues = PetAction.allCases.map(\.rawValue)
        XCTAssertEqual(rawValues.count, Set(rawValues).count, "Duplicate rawValues detected")
    }

    // MARK: - Species-Specific RawValue Init

    func testCatActions() {
        XCTAssertNotNil(PetAction(rawValue: "scratch"))
        XCTAssertNotNil(PetAction(rawValue: "stretch"))
        XCTAssertNotNil(PetAction(rawValue: "groom"))
        XCTAssertNotNil(PetAction(rawValue: "nap"))
    }

    func testDogActions() {
        XCTAssertNotNil(PetAction(rawValue: "dig"))
        XCTAssertNotNil(PetAction(rawValue: "fetchToy"))
        XCTAssertNotNil(PetAction(rawValue: "scratchWall"))
        // wagTail is legacy but still used by Dog
        XCTAssertNotNil(PetAction(rawValue: "wagTail"))
    }

    func testRabbitActions() {
        XCTAssertNotNil(PetAction(rawValue: "burrow"))
        XCTAssertNotNil(PetAction(rawValue: "nibble"))
        XCTAssertNotNil(PetAction(rawValue: "alertEars"))
        XCTAssertNotNil(PetAction(rawValue: "binky"))
    }

    func testBirdActions() {
        XCTAssertNotNil(PetAction(rawValue: "perch"))
        XCTAssertNotNil(PetAction(rawValue: "peck"))
        XCTAssertNotNil(PetAction(rawValue: "preen"))
        XCTAssertNotNil(PetAction(rawValue: "dive"))
        XCTAssertNotNil(PetAction(rawValue: "glide"))
    }

    func testFrogActions() {
        XCTAssertNotNil(PetAction(rawValue: "tongueSnap"))
        XCTAssertNotNil(PetAction(rawValue: "croak"))
        XCTAssertNotNil(PetAction(rawValue: "swim"))
        XCTAssertNotNil(PetAction(rawValue: "stickyWall"))
    }

    func testBearActions() {
        XCTAssertNotNil(PetAction(rawValue: "backScratch"))
        XCTAssertNotNil(PetAction(rawValue: "standUp"))
        XCTAssertNotNil(PetAction(rawValue: "pawSlam"))
        XCTAssertNotNil(PetAction(rawValue: "bigYawn"))
    }

    func testDragonActions() {
        XCTAssertNotNil(PetAction(rawValue: "breathFire"))
        XCTAssertNotNil(PetAction(rawValue: "hover"))
        XCTAssertNotNil(PetAction(rawValue: "wingSpread"))
        XCTAssertNotNil(PetAction(rawValue: "roar"))
    }

    func testOctopusActions() {
        XCTAssertNotNil(PetAction(rawValue: "inkSquirt"))
        XCTAssertNotNil(PetAction(rawValue: "tentacleReach"))
        XCTAssertNotNil(PetAction(rawValue: "camouflage"))
        XCTAssertNotNil(PetAction(rawValue: "wallSuction"))
    }

    func testGhostActions() {
        XCTAssertNotNil(PetAction(rawValue: "phaseThrough"))
        XCTAssertNotNil(PetAction(rawValue: "flicker"))
        XCTAssertNotNil(PetAction(rawValue: "spook"))
        XCTAssertNotNil(PetAction(rawValue: "vanish"))
    }

    func testSlimeActions() {
        XCTAssertNotNil(PetAction(rawValue: "split"))
        XCTAssertNotNil(PetAction(rawValue: "melt"))
        XCTAssertNotNil(PetAction(rawValue: "absorb"))
        XCTAssertNotNil(PetAction(rawValue: "wallStick"))
    }

    // MARK: - Codable Round-Trip

    func testCodableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for action in PetAction.allCases {
            let data = try encoder.encode(action)
            let decoded = try decoder.decode(PetAction.self, from: data)
            XCTAssertEqual(action, decoded, "Round-trip failed for \(action.rawValue)")
        }
    }

    // MARK: - Walk Alias

    func testWalkAlias() {
        XCTAssertEqual(PetAction.walk, .walking)
    }
}
