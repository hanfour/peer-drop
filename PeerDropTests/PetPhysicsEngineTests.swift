import XCTest
@testable import PeerDrop

final class PetPhysicsEngineTests: XCTestCase {

    func testGravityAcceleratesDownward() {
        var state = PetPhysicsState(position: CGPoint(x: 100, y: 100), velocity: .zero, surface: .airborne)
        let surfaces = ScreenSurfaces.test(ground: 800)
        PetPhysicsEngine.update(&state, dt: 1.0 / 60.0, surfaces: surfaces)
        XCTAssertGreaterThan(state.velocity.dy, 0, "Gravity should accelerate downward")
        XCTAssertGreaterThan(state.position.y, 100)
    }

    func testLandsOnGround() {
        // Start just above ground with large downward velocity
        var state = PetPhysicsState(position: CGPoint(x: 100, y: 799), velocity: CGVector(dx: 0, dy: 10), surface: .airborne)
        let surfaces = ScreenSurfaces.test(ground: 800)
        // Run enough ticks to land
        for _ in 0..<60 {
            PetPhysicsEngine.update(&state, dt: 1.0 / 60.0, surfaces: surfaces)
            if state.surface == .ground { break }
        }
        XCTAssertEqual(state.surface, .ground)
        XCTAssertEqual(state.position.y, 800, accuracy: 1)
    }

    func testWalkOnGround() {
        var state = PetPhysicsState(position: CGPoint(x: 100, y: 800), velocity: .zero, surface: .ground)
        let surfaces = ScreenSurfaces.test(ground: 800, rightWall: 400)
        PetPhysicsEngine.applyWalk(&state, direction: .right, speed: 30, dt: 1.0 / 60.0, surfaces: surfaces)
        XCTAssertGreaterThan(state.position.x, 100)
        XCTAssertEqual(state.position.y, 800, accuracy: 0.01, "Should stay on ground")
    }

    func testClimbWall() {
        var state = PetPhysicsState(position: CGPoint(x: 0, y: 500), velocity: .zero, surface: .leftWall)
        let surfaces = ScreenSurfaces.test(ceiling: 50)
        PetPhysicsEngine.applyClimb(&state, speed: 20, dt: 1.0 / 60.0, surfaces: surfaces)
        XCTAssertLessThan(state.position.y, 500, "Should climb upward")
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

    func testBounceOnHighVelocityLanding() {
        // High velocity landing should bounce (stay airborne with reversed dy)
        var state = PetPhysicsState(position: CGPoint(x: 100, y: 800), velocity: CGVector(dx: 50, dy: 300), surface: .airborne)
        let surfaces = ScreenSurfaces.test(ground: 800)
        PetPhysicsEngine.resolveCollision(&state, surfaces: surfaces)
        XCTAssertEqual(state.surface, .airborne, "Should still be airborne after bounce")
        XCTAssertLessThan(state.velocity.dy, 0, "Should bounce upward")
    }

    func testLowVelocityLandingSettles() {
        // Low velocity landing should settle on ground
        var state = PetPhysicsState(position: CGPoint(x: 100, y: 800), velocity: CGVector(dx: 5, dy: 10), surface: .airborne)
        let surfaces = ScreenSurfaces.test(ground: 800)
        PetPhysicsEngine.resolveCollision(&state, surfaces: surfaces)
        XCTAssertEqual(state.surface, .ground)
        XCTAssertEqual(state.velocity.dy, 0, accuracy: 0.01)
    }
}
