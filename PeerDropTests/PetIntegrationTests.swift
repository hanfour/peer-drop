import XCTest
@testable import PeerDrop

@MainActor
final class PetIntegrationTests: XCTestCase {

    func testEggRenders128px() {
        let engine = PetEngine(pet: .newEgg())
        engine.updateRenderedImage()
        XCTAssertNotNil(engine.renderedImage)
        XCTAssertEqual(engine.renderedImage?.width, 128)
    }

    func testBabyRenders128px() {
        var pet = PetState.newEgg()
        pet.level = .baby
        pet.genome.body = .cat
        let engine = PetEngine(pet: pet)
        engine.updateRenderedImage()
        XCTAssertNotNil(engine.renderedImage)
        XCTAssertEqual(engine.renderedImage?.width, 128)
    }

    func testTapInteractionUpdatesState() {
        var pet = PetState.newEgg()
        pet.level = .baby
        pet.genome.body = .cat
        let engine = PetEngine(pet: pet)
        let oldExp = engine.pet.experience
        engine.handleInteraction(.tap)
        XCTAssertGreaterThan(engine.pet.experience, oldExp)
    }

    func testEggDoesNotMove() {
        let engine = PetEngine(pet: .newEgg())
        let action = PetBehaviorController.nextBehavior(
            current: .idle, physics: engine.physicsState, level: .egg, elapsed: 100)
        XCTAssertEqual(action, .idle)
    }
}
