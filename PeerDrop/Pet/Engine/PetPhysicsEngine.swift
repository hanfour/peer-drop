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

    enum HorizontalDirection { case left, right }
}
