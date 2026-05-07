import XCTest
@testable import PeerDrop

@MainActor
final class PetIntegrationTests: XCTestCase {

    // testEggRenders128px and testBabyRenders128px were removed by the M4.4
    // V2→V3 migration — they asserted V2-specific behavior (scale=8 → 128px
    // synchronous output) that doesn't apply to the v4.0 PNG pipeline (raw
    // PNG dimensions, async via SpriteService, requires assets bundled into
    // the main app bundle which is pending M5). M11 will write fresh
    // integration tests against the v4.0 contract once M5 lands assets.

    func testTapInteractionUpdatesState() {
        var pet = PetState.newEgg()
        pet.level = .baby
        pet.genome.body = .cat
        let engine = PetEngine(pet: pet)
        let oldExp = engine.pet.experience
        engine.handleInteraction(.tap)
        XCTAssertGreaterThan(engine.pet.experience, oldExp)
    }
}
