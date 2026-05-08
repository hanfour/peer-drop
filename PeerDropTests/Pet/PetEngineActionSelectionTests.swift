import XCTest
import CoreGraphics
@testable import PeerDrop

@MainActor
final class PetEngineActionSelectionTests: XCTestCase {

    // MARK: - Pure mapping (no engine instance needed)

    func test_actionFromVelocity_zero_returnsIdle() {
        let action = PetEngine.actionFromVelocity(.zero)
        XCTAssertEqual(action, .idle)
    }

    func test_actionFromVelocity_belowThreshold_returnsIdle() {
        let action = PetEngine.actionFromVelocity(CGVector(dx: 3, dy: 0))
        XCTAssertEqual(action, .idle, "3 px/s below the 5 px/s threshold = idle")
    }

    func test_actionFromVelocity_aboveThreshold_returnsWalking() {
        let action = PetEngine.actionFromVelocity(CGVector(dx: 50, dy: 0))
        XCTAssertEqual(action, .walking)
    }

    func test_actionFromVelocity_diagonalAboveThreshold_returnsWalking() {
        // Magnitude = hypot(4, 4) ≈ 5.66 > 5
        let action = PetEngine.actionFromVelocity(CGVector(dx: 4, dy: 4))
        XCTAssertEqual(action, .walking)
    }

    func test_actionFromVelocity_diagonalBelowThreshold_returnsIdle() {
        // Magnitude = hypot(3, 3) ≈ 4.24 < 5
        let action = PetEngine.actionFromVelocity(CGVector(dx: 3, dy: 3))
        XCTAssertEqual(action, .idle)
    }

    // MARK: - Engine integration: physicsState transitions drive animator

    private func makeEngine() -> PetEngine {
        let testBundle = Bundle(for: type(of: self))
        let service = SpriteService(cache: SpriteCache(countLimit: 30), bundle: testBundle)
        let renderer = PetRendererV3(service: service)
        var pet = PetState.newEgg()
        pet.level = .adult
        pet.genome.body = .cat
        pet.genome.subVariety = "tabby"
        return PetEngine(
            pet: pet,
            rendererV3: renderer,
            sharedRenderedPet: SharedRenderedPet(suiteName: nil)
        )
    }

    func test_engine_initialState_animatorIsIdle() async throws {
        let engine = makeEngine()
        // Combine subscription emits the initial physicsState (velocity .zero)
        // → action .idle. dispatchActionToAnimator runs a Task. Wait for it.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(engine.animator.currentAction, .idle)
        engine.animator.stopAnimation()
    }

    func test_engine_velocityAboveThreshold_transitionsAnimatorToWalking() async throws {
        let engine = makeEngine()
        // Wait for initial idle dispatch to complete
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(engine.animator.currentAction, .idle)

        engine.physicsState = PetPhysicsState(
            position: engine.physicsState.position,
            velocity: CGVector(dx: 60, dy: 0),
            surface: .ground)

        // Combine pipeline + Task hop
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(engine.animator.currentAction, .walking)
        engine.animator.stopAnimation()
    }

    func test_engine_velocityReturnsToZero_animatorBackToIdle() async throws {
        let engine = makeEngine()
        try await Task.sleep(nanoseconds: 200_000_000)

        engine.physicsState = PetPhysicsState(
            position: engine.physicsState.position,
            velocity: CGVector(dx: 60, dy: 0),
            surface: .ground)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(engine.animator.currentAction, .walking)

        engine.physicsState = PetPhysicsState(
            position: engine.physicsState.position,
            velocity: .zero,
            surface: .ground)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(engine.animator.currentAction, .idle)
        engine.animator.stopAnimation()
    }
}
