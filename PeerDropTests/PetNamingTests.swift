import XCTest
@testable import PeerDrop

@MainActor
final class PetNamingTests: XCTestCase {
    func testEvolutionToBabyShowsNamingWhenNoName() {
        var pet = PetState.newEgg()
        pet.experience = 99
        pet.birthDate = Date().addingTimeInterval(-86401)
        let engine = PetEngine(pet: pet)
        engine.handleInteraction(.tap)
        XCTAssertEqual(engine.pet.level, .baby)
        XCTAssertTrue(engine.showNamingDialog)
    }

    func testEvolutionDoesNotShowNamingWhenNamed() {
        var pet = PetState.newEgg()
        pet.name = "Pixel"
        pet.experience = 99
        pet.birthDate = Date().addingTimeInterval(-86401)
        let engine = PetEngine(pet: pet)
        engine.handleInteraction(.tap)
        XCTAssertFalse(engine.showNamingDialog)
    }
}
