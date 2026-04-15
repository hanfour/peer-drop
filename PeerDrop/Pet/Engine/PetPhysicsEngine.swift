import CoreGraphics

enum PetPhysicsEngine {

    static let gravity: CGFloat = 800
    static let bounceRestitution: CGFloat = 0.3
    static let throwDecay: CGFloat = 0.95
    static let petSize: CGFloat = 16

    // MARK: - Core Physics

    static func update(_ state: inout PetPhysicsState, dt: CGFloat, surfaces: ScreenSurfaces,
                       profile: PetBehaviorProfile? = nil) {
        guard state.surface == .airborne else { return }
        let effectiveGravity = profile?.gravity ?? gravity
        state.velocity.dy += effectiveGravity * dt
        state.velocity.dx *= throwDecay
        state.position.x += state.velocity.dx * dt
        state.position.y += state.velocity.dy * dt
        let passThroughWalls = profile?.canPassThroughWalls ?? false
        resolveCollision(&state, surfaces: surfaces, canPassThroughWalls: passThroughWalls)
    }

    static func resolveCollision(_ state: inout PetPhysicsState, surfaces: ScreenSurfaces,
                                 canPassThroughWalls: Bool = false) {
        guard !canPassThroughWalls else { return }

        if state.position.y >= surfaces.ground {
            state.position.y = surfaces.ground
            if abs(state.velocity.dy) > 20 {
                state.velocity.dy = -state.velocity.dy * bounceRestitution
            } else {
                state.velocity = .zero
                state.surface = .ground
            }
        }
        if state.position.y <= surfaces.ceiling {
            state.position.y = surfaces.ceiling
            state.velocity.dy = 0
            state.surface = .ceiling
        }
        if state.position.x <= surfaces.leftWall {
            state.position.x = surfaces.leftWall
            state.velocity.dx = 0
            state.surface = .leftWall
        }
        if state.position.x >= surfaces.rightWall - petSize {
            state.position.x = surfaces.rightWall - petSize
            state.velocity.dx = 0
            state.surface = .rightWall
        }
    }

    // MARK: - Movement Methods

    static func applyWalk(_ state: inout PetPhysicsState, direction: HorizontalDirection,
                          speed: CGFloat, dt: CGFloat, surfaces: ScreenSurfaces) {
        let dx = direction == .right ? speed * dt : -speed * dt
        state.position.x += dx
        state.facingRight = direction == .right
        state.position.x = max(surfaces.leftWall, min(state.position.x, surfaces.rightWall - petSize))
    }

    static func applyClimb(_ state: inout PetPhysicsState, speed: CGFloat,
                           dt: CGFloat, surfaces: ScreenSurfaces) {
        state.position.y -= speed * dt
        if state.position.y <= surfaces.ceiling {
            state.position.y = surfaces.ceiling
            state.surface = .ceiling
        }
    }

    static func applyJump(_ state: inout PetPhysicsState, jumpVelocity: CGFloat = -300) {
        state.velocity.dy = jumpVelocity
        state.surface = .airborne
    }

    static func applyThrow(_ state: inout PetPhysicsState, velocity: CGVector) {
        state.velocity = velocity
        state.surface = .airborne
    }

    /// Flying — free directional movement, no gravity, clamped to screen
    static func applyFly(_ state: inout PetPhysicsState, direction: CGVector,
                         speed: CGFloat, dt: CGFloat, surfaces: ScreenSurfaces) {
        let len = hypot(direction.dx, direction.dy)
        guard len > 0 else { return }
        let nx = direction.dx / len
        let ny = direction.dy / len
        state.position.x += nx * speed * dt
        state.position.y += ny * speed * dt
        state.facingRight = nx >= 0
        state.position.x = max(surfaces.leftWall, min(state.position.x, surfaces.rightWall - petSize))
        state.position.y = max(surfaces.ceiling, min(state.position.y, surfaces.ground))
    }

    /// Floating — free directional, ignores all surfaces
    static func applyFloat(_ state: inout PetPhysicsState, direction: CGVector,
                           speed: CGFloat, dt: CGFloat) {
        let len = hypot(direction.dx, direction.dy)
        guard len > 0 else { return }
        state.position.x += (direction.dx / len) * speed * dt
        state.position.y += (direction.dy / len) * speed * dt
        state.facingRight = direction.dx >= 0
    }

    /// Hop — horizontal jump from ground
    static func applyHop(_ state: inout PetPhysicsState, direction: HorizontalDirection,
                         speed: CGFloat, jumpVelocity: CGFloat = -250) {
        state.velocity.dy = jumpVelocity
        state.velocity.dx = direction == .right ? speed : -speed
        state.surface = .airborne
        state.facingRight = direction == .right
    }

    /// Bounce — vertical bounce in place
    static func applyBounce(_ state: inout PetPhysicsState, jumpVelocity: CGFloat = -200) {
        state.velocity.dy = jumpVelocity
        state.surface = .airborne
    }

    enum HorizontalDirection { case left, right }
}
