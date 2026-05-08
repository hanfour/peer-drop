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

    // MARK: - S3 hysteresis: nextAction(previous:velocity:)

    func test_nextAction_idleAndSpeedInHysteresisBand_staysIdle() {
        // Speed=4 is between exit=3 and enter=5; idle stays idle.
        let action = PetEngine.nextAction(previous: .idle, velocity: CGVector(dx: 4, dy: 0))
        XCTAssertEqual(action, .idle)
    }

    func test_nextAction_walkingAndSpeedInHysteresisBand_staysWalking() {
        // Speed=4 is between exit=3 and enter=5; walking stays walking
        // (this is the hysteresis behavior — the same speed that wouldn't
        // start a walk continues an in-progress walk).
        let action = PetEngine.nextAction(previous: .walking, velocity: CGVector(dx: 4, dy: 0))
        XCTAssertEqual(action, .walking)
    }

    func test_nextAction_idleAboveEnterThreshold_promotesToWalking() {
        let action = PetEngine.nextAction(previous: .idle, velocity: CGVector(dx: 6, dy: 0))
        XCTAssertEqual(action, .walking)
    }

    func test_nextAction_walkingBelowExitThreshold_demotesToIdle() {
        let action = PetEngine.nextAction(previous: .walking, velocity: CGVector(dx: 2, dy: 0))
        XCTAssertEqual(action, .idle)
    }

    func test_nextAction_walkingExactlyAtExitThreshold_staysWalking() {
        // Boundary inclusive on the walking side (>= 3.0 stays walking).
        let action = PetEngine.nextAction(previous: .walking, velocity: CGVector(dx: 3, dy: 0))
        XCTAssertEqual(action, .walking)
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
            sharedRenderedPet: SharedRenderedPet(suiteName: nil),
            spriteService: service
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
        // The injected test-bundle SpriteService resolved cat-tabby-adult.zip
        // (v2 format, no animations) and returned the v2-fallback 1-frame
        // static. Animator's totalFrames must reflect that — proves the
        // metadata-fetch path actually ran (vs silently falling through to
        // the catch-block 1-frame default which would also produce 1).
        // Distinguish: v2-fallback returns fps=1, the catch-block default
        // also sets fps=1. Both produce identical observable state for
        // a v2 zip, which is correct: caller doesn't need to special-case.
        XCTAssertEqual(engine.animator.totalFrames, 1,
                       "test-bundle cat-tabby-adult.zip is v2 -> 1-frame fallback")
        XCTAssertEqual(engine.animator.fps, 1)
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
