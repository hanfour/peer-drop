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

    func testBounceOnLanding() {
        var state = PetPhysicsState(position: CGPoint(x: 100, y: 800), velocity: CGVector(dx: 50, dy: 300), surface: .airborne)
        let surfaces = ScreenSurfaces.test(ground: 800)
        PetPhysicsEngine.resolveCollision(&state, surfaces: surfaces)
        // High velocity causes a bounce — pet stays airborne with reversed dy
        XCTAssertEqual(state.surface, .airborne)
        XCTAssertLessThan(state.velocity.dy, 0)
        XCTAssertEqual(state.velocity.dy, -300 * PetPhysicsEngine.bounceRestitution, accuracy: 0.01)
    }

    // MARK: - Profile-aware physics

    func testNoGravityForFlyingMode() {
        var state = PetPhysicsState(position: CGPoint(x: 100, y: 100), velocity: .zero, surface: .airborne)
        let surfaces = ScreenSurfaces.test(ground: 800)
        let birdProfile = PetBehaviorProviderFactory.create(for: .bird).profile
        PetPhysicsEngine.update(&state, dt: 1.0 / 60.0, surfaces: surfaces, profile: birdProfile)
        XCTAssertEqual(state.velocity.dy, 0, accuracy: 0.01)
    }

    func testGhostPassesThroughWalls() {
        var state = PetPhysicsState(position: CGPoint(x: -10, y: 400), velocity: CGVector(dx: -50, dy: 0), surface: .airborne)
        let surfaces = ScreenSurfaces.test(leftWall: 0, rightWall: 400)
        let ghostProfile = PetBehaviorProviderFactory.create(for: .ghost).profile
        PetPhysicsEngine.update(&state, dt: 1.0 / 60.0, surfaces: surfaces, profile: ghostProfile)
        XCTAssertLessThan(state.position.x, 0)
    }

    func testReducedGravityForCrawling() {
        var state = PetPhysicsState(position: CGPoint(x: 100, y: 100), velocity: .zero, surface: .airborne)
        let surfaces = ScreenSurfaces.test(ground: 800)
        let octopusProfile = PetBehaviorProviderFactory.create(for: .octopus).profile
        PetPhysicsEngine.update(&state, dt: 1.0 / 60.0, surfaces: surfaces, profile: octopusProfile)
        let expectedDy = 400.0 / 60.0
        XCTAssertEqual(state.velocity.dy, expectedDy, accuracy: 0.5)
    }
}
