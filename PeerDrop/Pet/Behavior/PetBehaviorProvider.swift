import CoreGraphics
import Foundation

// MARK: - Physics Mode

enum PetPhysicsMode: String {
    case grounded   // gravity, ground/wall (cat, dog, rabbit, bear)
    case flying     // no gravity, free movement (bird, dragon)
    case floating   // no gravity, no collision, pass through walls (ghost)
    case bouncing   // gravity with bounce (frog, slime)
    case crawling   // reduced gravity, attach any surface (octopus)
}

// MARK: - Movement Style

enum MovementStyle: String {
    case walk       // cat, dog, bear
    case hop        // rabbit, frog
    case fly        // bird, dragon
    case slither    // octopus
    case float      // ghost
    case bounce     // slime
}

// MARK: - Exit/Enter Styles

enum PetExitStyle {
    case perspectiveWalk   // cat
    case digDown           // dog, rabbit
    case flyOff            // bird
    case hopOff            // frog
    case walkOff           // bear
    case skyAscend         // dragon
    case inkVanish         // octopus
    case fadeOut           // ghost
    case meltDown          // slime
}

enum PetEnterStyle {
    case perspectiveReturn
    case digUp
    case flyIn
    case hopIn
    case walkIn
    case skyDescend
    case inkAppear
    case fadeIn
    case reformUp
}

// MARK: - Chat Interaction

enum ChatPetPosition {
    case onTop(offset: CGFloat)
    case beside(leading: Bool)
    case stickedOn(leading: Bool)
    case wrappedAround
    case behind
    case above(height: CGFloat)
    case between(upperIndex: Int)
    case leaningOn(leading: Bool)
    case coiled
    case dripping
}

struct ChatPetAction {
    let targetMessageIndex: Int?
    let position: ChatPetPosition
    let action: PetAction
    let duration: TimeInterval
}

// MARK: - Animation Sequence

struct PetAnimationStep {
    let action: PetAction
    let duration: TimeInterval
    let positionDelta: CGPoint?
    let scaleDelta: CGFloat?
    let opacityDelta: CGFloat?
}

struct PetAnimationSequence {
    let steps: [PetAnimationStep]
}

// MARK: - Behavior Profile

struct PetBehaviorProfile {
    let physicsMode: PetPhysicsMode
    let gravity: CGFloat
    let canClimbWalls: Bool
    let canHangCeiling: Bool
    let canPassThroughWalls: Bool
    let baseSpeed: CGFloat
    let movementStyle: MovementStyle
    let idleDurationRange: ClosedRange<TimeInterval>
    let moveDurationRange: ClosedRange<TimeInterval>
    let uniqueActions: [PetAction]
    let exitStyle: PetExitStyle
    let enterStyle: PetEnterStyle
}

// MARK: - Provider Protocol

protocol PetBehaviorProvider {
    var profile: PetBehaviorProfile { get }

    func nextBehavior(current: PetAction, physics: PetPhysicsState, level: PetLevel,
                      elapsed: TimeInterval, foodTarget: CGPoint?,
                      traits: PersonalityTraits) -> PetAction

    func exitSequence(from position: CGPoint, screenBounds: CGRect) -> PetAnimationSequence

    func enterSequence(screenBounds: CGRect) -> PetAnimationSequence

    func chatBehavior(messageFrames: [CGRect], petPosition: CGPoint) -> ChatPetAction?

    func modifyPhysics(_ state: inout PetPhysicsState, deltaTime: CGFloat, surfaces: ScreenSurfaces)
}

// MARK: - Default Implementations

extension PetBehaviorProvider {
    func nextBehavior(current: PetAction, physics: PetPhysicsState, level: PetLevel,
                      elapsed: TimeInterval, foodTarget: CGPoint?,
                      traits: PersonalityTraits) -> PetAction {
        // Chase food
        if let target = foodTarget, physics.surface == .ground {
            let dist = hypot(physics.position.x - target.x, physics.position.y - target.y)
            if dist > 8 { return .run }
        }

        // Airborne -> fall (for grounded/bouncing)
        if physics.surface == .airborne
            && profile.physicsMode != .flying
            && profile.physicsMode != .floating {
            return .fall
        }

        // Default idle -> walk
        if current == .idle && physics.surface == .ground {
            let idleThreshold = traits.energy > 0.7
                ? profile.idleDurationRange.lowerBound
                : profile.idleDurationRange.upperBound
            if elapsed > idleThreshold {
                return Bool.random() ? .walking : .idle
            }
        }

        if current == .walking && physics.surface == .ground {
            if elapsed > profile.moveDurationRange.upperBound { return .idle }
        }

        if current == .thrown || current == .fall { return current }

        return current
    }

    func exitSequence(from position: CGPoint, screenBounds: CGRect) -> PetAnimationSequence {
        PetAnimationSequence(steps: [
            PetAnimationStep(action: .walking, duration: 3.0,
                             positionDelta: CGPoint(x: screenBounds.width, y: 0),
                             scaleDelta: nil, opacityDelta: 0.0),
        ])
    }

    func enterSequence(screenBounds: CGRect) -> PetAnimationSequence {
        PetAnimationSequence(steps: [
            PetAnimationStep(action: .walking, duration: 3.0,
                             positionDelta: CGPoint(x: screenBounds.width / 2,
                                                    y: screenBounds.height - 80),
                             scaleDelta: nil, opacityDelta: 1.0),
        ])
    }

    func chatBehavior(messageFrames: [CGRect], petPosition: CGPoint) -> ChatPetAction? {
        nil
    }

    func modifyPhysics(_ state: inout PetPhysicsState, deltaTime: CGFloat, surfaces: ScreenSurfaces) {
        // No modification by default
    }
}
