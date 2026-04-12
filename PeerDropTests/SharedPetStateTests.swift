import XCTest
@testable import PeerDrop

final class SharedPetStateTests: XCTestCase {
    func testWriteAndReadPetSnapshot() {
        let shared = SharedPetState(suiteName: nil)
        let snapshot = PetSnapshot(
            name: "Pixel", bodyType: .cat, eyeType: .dot, patternType: .none,
            level: .baby, mood: .happy, paletteIndex: 0, experience: 42, maxExperience: 500)
        shared.write(snapshot)
        let read = shared.read()
        XCTAssertNotNil(read)
        XCTAssertEqual(read?.name, "Pixel")
        XCTAssertEqual(read?.bodyType, .cat)
        XCTAssertEqual(read?.level, .baby)
        XCTAssertEqual(read?.experience, 42)
    }

    func testReadReturnsNilWhenEmpty() {
        let shared = SharedPetState(suiteName: nil)
        shared.clear()
        XCTAssertNil(shared.read())
    }
}
