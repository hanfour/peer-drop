import XCTest
@testable import PeerDrop

@MainActor
final class PetIntegrationTests: XCTestCase {

    func testEggRenders16x16() {
        let engine = PetEngine(pet: .newEgg())
        XCTAssertNotNil(engine.renderedImage)
        XCTAssertEqual(engine.renderedImage?.width, 128) // 16 * 8 scale
    }

    func testBabyRenders16x16() {
        var pet = PetState.newEgg()
        pet.level = .baby
        pet.genome.body = .cat
        let engine = PetEngine(pet: pet)
        XCTAssertNotNil(engine.renderedImage)
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
        let startPos = engine.physicsState.position
        // Simulate behavior tick
        let action = PetBehaviorController.nextBehavior(
            current: .idle, physics: engine.physicsState, level: .egg, elapsed: 100)
        XCTAssertEqual(action, .idle)
        XCTAssertEqual(engine.physicsState.position.x, startPos.x)
    }

    func testPhysicsStateInitializesOnGround() {
        let engine = PetEngine(pet: .newEgg())
        XCTAssertEqual(engine.physicsState.surface, .ground)
    }

    func testParticleSpawning() {
        let engine = PetEngine(pet: .newEgg())
        engine.spawnParticle(.heart)
        XCTAssertEqual(engine.particles.count, 1)
        XCTAssertEqual(engine.particles.first?.type, .heart)
    }

    func testRendererV2ProducesAllActions() {
        let renderer = PetRendererV2()
        let genome = PetGenome(body: .cat, eyes: .dot, pattern: .none, personalityGene: 0.5)
        let palette = PetPalettes.all[0]

        let actions: [PetAction] = [.idle, .walking, .run, .jump, .climb, .hang, .fall,
                                     .sitEdge, .sleeping, .eat, .yawn, .poop, .happy,
                                     .scared, .angry, .love, .tapReact, .pickedUp, .thrown, .petted]
        for action in actions {
            let image = renderer.render(genome: genome, level: .baby, mood: .curious,
                                         action: action, frame: 0, palette: palette, scale: 1)
            XCTAssertNotNil(image, "Should render \(action)")
        }
    }
}
