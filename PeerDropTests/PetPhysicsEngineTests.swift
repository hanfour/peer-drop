import XCTest
@testable import PeerDrop

final class PetPhysicsEngineTests: XCTestCase {

    func testGravityAcceleratesDownward() {
        var state = PetPhysicsState(position: CGPoint(x: 100, y: 100), velocity: .zero, surface: .airborne)
        let surfaces = ScreenSurfaces.test(ground: 800)
        PetPhysicsEngine.update(&state, dt: 1.0 / 60.0, surfaces: surfaces)
        XCTAssertGreaterThan(state.velocity.dy, 0)
        XCTAssertGreaterThan(state.position.y, 100)
    }

    func testLandsOnGround() {
        // Place pet just above ground with velocity low enough to not bounce (abs(dy) <= 20)
        var state = PetPhysicsState(position: CGPoint(x: 100, y: 800), velocity: CGVector(dx: 0, dy: 15), surface: .airborne)
        let surfaces = ScreenSurfaces.test(ground: 800)
        // resolveCollision is called within update; pet is already at ground level
        PetPhysicsEngine.resolveCollision(&state, surfaces: surfaces)
        XCTAssertEqual(state.surface, .ground)
        XCTAssertEqual(state.position.y, 800, accuracy: 0.01)
        XCTAssertEqual(state.velocity.dy, 0, accuracy: 0.01)
    }

    func testWalkOnGround() {
        var state = PetPhysicsState(position: CGPoint(x: 100, y: 800), velocity: .zero, surface: .ground)
        let surfaces = ScreenSurfaces.test(ground: 800, rightWall: 400)
        PetPhysicsEngine.applyWalk(&state, direction: .right, speed: 30, dt: 1.0 / 60.0, surfaces: surfaces)
        XCTAssertGreaterThan(state.position.x, 100)
        XCTAssertEqual(state.position.y, 800, accuracy: 0.01)
    }

    func testClimbWall() {
        var state = PetPhysicsState(position: CGPoint(x: 0, y: 500), velocity: .zero, surface: .leftWall)
        let surfaces = ScreenSurfaces.test(ceiling: 50)
        PetPhysicsEngine.applyClimb(&state, speed: 20, dt: 1.0 / 60.0, surfaces: surfaces)
        XCTAssertLessThan(state.position.y, 500)
    }

    func testClimbReachesCeiling() {
        var state = PetPhysicsState(position: CGPoint(x: 0, y: 51), velocity: .zero, surface: .leftWall)
        let surfaces = ScreenSurfaces.test(ceiling: 50)
        PetPhysicsEngine.applyClimb(&state, speed: 20, dt: 1.0, surfaces: surfaces)
        XCTAssertEqual(state.surface, .ceiling)
    }

    func testThrowAppliesVelocity() {
        var state = PetPhysicsState(position: CGPoint(x: 200, y: 200), velocity: .zero, surface: .airborne)
        PetPhysicsEngine.applyThrow(&state, velocity: CGVector(dx: 100, dy: -200))
        XCTAssertEqual(state.velocity.dx, 100)
        XCTAssertEqual(state.velocity.dy, -200)
    }

    func testBounceOnLanding_bouncingMode() {
        // v5.0.x: bouncing is now opt-in via physicsMode (frog/slime only).
        // Grounded pets land cleanly — see testGroundedPetLandsCleanly below.
        var state = PetPhysicsState(position: CGPoint(x: 100, y: 800), velocity: CGVector(dx: 50, dy: 300), surface: .airborne)
        let surfaces = ScreenSurfaces.test(ground: 800)
        PetPhysicsEngine.resolveCollision(&state, surfaces: surfaces, physicsMode: .bouncing)
        XCTAssertEqual(state.surface, .airborne)
        XCTAssertLessThan(state.velocity.dy, 0)
        XCTAssertEqual(state.velocity.dy, -300 * PetPhysicsEngine.bounceRestitution, accuracy: 0.01)
    }

    func testGroundedPetLandsCleanly() {
        // Cats, dogs, etc. should NOT hop on landing — that produced the
        // "unnatural drop with little bounces" feedback on drag release.
        var state = PetPhysicsState(position: CGPoint(x: 100, y: 800), velocity: CGVector(dx: 50, dy: 300), surface: .airborne)
        let surfaces = ScreenSurfaces.test(ground: 800)
        PetPhysicsEngine.resolveCollision(&state, surfaces: surfaces, physicsMode: .grounded)
        XCTAssertEqual(state.surface, .ground, "grounded pet should land, not bounce")
        XCTAssertEqual(state.velocity, .zero, "velocity zeroed on clean landing")
    }

    func testWalkBouncesOffLeftWall() {
        var state = PetPhysicsState(position: CGPoint(x: 20, y: 800), velocity: .zero, surface: .ground)
        state.facingRight = false
        let surfaces = ScreenSurfaces.test(ground: 800, leftWall: 20, rightWall: 400)
        // Walk left into the wall — should clamp + flip facing direction.
        PetPhysicsEngine.applyWalk(&state, direction: .left, speed: 100, dt: 1.0 / 60.0, surfaces: surfaces)
        XCTAssertEqual(state.position.x, 20, "clamped at left wall")
        XCTAssertTrue(state.facingRight, "facing flipped to walk back right")
    }

    func testWalkBouncesOffRightWall() {
        let rightBound = 400 - PetPhysicsEngine.petSize
        var state = PetPhysicsState(position: CGPoint(x: rightBound, y: 800), velocity: .zero, surface: .ground)
        state.facingRight = true
        let surfaces = ScreenSurfaces.test(ground: 800, leftWall: 20, rightWall: 400)
        PetPhysicsEngine.applyWalk(&state, direction: .right, speed: 100, dt: 1.0 / 60.0, surfaces: surfaces)
        XCTAssertEqual(state.position.x, rightBound, "clamped at right wall (rightWall - petSize)")
        XCTAssertFalse(state.facingRight, "facing flipped to walk back left")
    }

    func testWalkSnapsYToGround() {
        // Pet's y drifted from the actual ground — applyWalk should put it
        // back on the floor. Fixes "cat walking through the middle of the
        // screen" after default-init or screen resize.
        var state = PetPhysicsState(position: CGPoint(x: 200, y: 200), velocity: .zero, surface: .ground)
        let surfaces = ScreenSurfaces.test(ground: 800, rightWall: 400)
        PetPhysicsEngine.applyWalk(&state, direction: .right, speed: 30, dt: 1.0 / 60.0, surfaces: surfaces)
        XCTAssertEqual(state.position.y, 800, accuracy: 0.01, "y snapped to ground level")
    }

    // MARK: - Profile-aware physics

    func testNoGravityForFlyingMode() {
        var state = PetPhysicsState(position: CGPoint(x: 100, y: 100), velocity: .zero, surface: .airborne)
        let surfaces = ScreenSurfaces.test(ground: 800)
        let birdProfile = PetBehaviorProviderFactory.create(for: .bird).profile
        PetPhysicsEngine.update(&state, dt: 1.0 / 60.0, surfaces: surfaces, profile: birdProfile)
        XCTAssertEqual(state.velocity.dy, 0, accuracy: 0.01)
    }

    func testReducedGravityForCrawling() {
        var state = PetPhysicsState(position: CGPoint(x: 100, y: 100), velocity: .zero, surface: .airborne)
        let surfaces = ScreenSurfaces.test(ground: 800)
        let octopusProfile = PetBehaviorProviderFactory.create(for: .octopus).profile
        PetPhysicsEngine.update(&state, dt: 1.0 / 60.0, surfaces: surfaces, profile: octopusProfile)
        let expectedDy = 400.0 / 60.0
        XCTAssertEqual(state.velocity.dy, expectedDy, accuracy: 0.5)
    }

    // MARK: - New movement methods

    func testApplyFly() {
        var state = PetPhysicsState(position: CGPoint(x: 200, y: 300), velocity: .zero, surface: .airborne)
        let surfaces = ScreenSurfaces.test()
        PetPhysicsEngine.applyFly(&state, direction: CGVector(dx: 1, dy: -0.5), speed: 90, dt: 1.0 / 60.0, surfaces: surfaces)
        XCTAssertGreaterThan(state.position.x, 200)
        XCTAssertLessThan(state.position.y, 300)
    }

    func testApplyHop() {
        var state = PetPhysicsState(position: CGPoint(x: 200, y: 780), velocity: .zero, surface: .ground)
        PetPhysicsEngine.applyHop(&state, direction: .right, speed: 75, jumpVelocity: -250)
        XCTAssertEqual(state.surface, .airborne)
        XCTAssertLessThan(state.velocity.dy, 0)
        XCTAssertGreaterThan(state.velocity.dx, 0)
    }

    func testApplyBounce() {
        var state = PetPhysicsState(position: CGPoint(x: 200, y: 780), velocity: .zero, surface: .ground)
        PetPhysicsEngine.applyBounce(&state, jumpVelocity: -200)
        XCTAssertEqual(state.surface, .airborne)
        XCTAssertLessThan(state.velocity.dy, 0)
    }
}
