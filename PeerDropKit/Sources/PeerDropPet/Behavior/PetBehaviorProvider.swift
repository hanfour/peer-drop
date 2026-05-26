import CoreGraphics
import Foundation

// MARK: - Physics Mode

public enum PetPhysicsMode: String {
    case grounded   // gravity, ground/wall (cat, dog, rabbit, bear)
    case flying     // no gravity, free movement (bird, dragon)
    case bouncing   // gravity with bounce (frog, slime)
    case crawling   // reduced gravity, attach any surface (octopus)
}

// MARK: - Movement Style

public enum MovementStyle: String {
    case walk       // cat, dog, bear
    case hop        // rabbit, frog
    case fly        // bird, dragon
    case slither    // octopus
    case bounce     // slime
}

// MARK: - Exit/Enter Styles

public enum PetExitStyle {
    case perspectiveWalk   // cat
    case digDown           // dog, rabbit
    case flyOff            // bird
    case hopOff            // frog
    case walkOff           // bear
    case skyAscend         // dragon
    case inkVanish         // octopus
    case meltDown          // slime
}

public enum PetEnterStyle {
    case perspectiveReturn
    case digUp
    case flyIn
    case hopIn
    case walkIn
    case skyDescend
    case inkAppear
    case reformUp
}

// MARK: - Chat Interaction

public enum ChatPetPosition {
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

public struct ChatPetAction {
    public let targetMessageIndex: Int?
    public let position: ChatPetPosition
    public let action: PetAction
    public let duration: TimeInterval
    public init(targetMessageIndex: Int?, position: ChatPetPosition, action: PetAction, duration: TimeInterval) {
        self.targetMessageIndex = targetMessageIndex
        self.position = position
        self.action = action
        self.duration = duration
    }
}

// MARK: - Animation Sequence

public struct PetAnimationStep {
    public let action: PetAction
    public let duration: TimeInterval
    public let positionDelta: CGPoint?
    public let scaleDelta: CGFloat?
    public let opacityDelta: CGFloat?
    public init(action: PetAction, duration: TimeInterval, positionDelta: CGPoint?, scaleDelta: CGFloat?, opacityDelta: CGFloat?) {
        self.action = action
        self.duration = duration
        self.positionDelta = positionDelta
        self.scaleDelta = scaleDelta
        self.opacityDelta = opacityDelta
    }
}

public struct PetAnimationSequence {
    public let steps: [PetAnimationStep]
    public init(steps: [PetAnimationStep]) { self.steps = steps }
}

// MARK: - Behavior Profile

public struct PetBehaviorProfile {
    public let physicsMode: PetPhysicsMode
    public let gravity: CGFloat
    public let canClimbWalls: Bool
    public let canHangCeiling: Bool
    public let canPassThroughWalls: Bool
    public let baseSpeed: CGFloat
    public let movementStyle: MovementStyle
    public let idleDurationRange: ClosedRange<TimeInterval>
    public let moveDurationRange: ClosedRange<TimeInterval>
    public let uniqueActions: [PetAction]
    public let exitStyle: PetExitStyle
    public let enterStyle: PetEnterStyle
    public init(physicsMode: PetPhysicsMode, gravity: CGFloat, canClimbWalls: Bool, canHangCeiling: Bool, canPassThroughWalls: Bool, baseSpeed: CGFloat, movementStyle: MovementStyle, idleDurationRange: ClosedRange<TimeInterval>, moveDurationRange: ClosedRange<TimeInterval>, uniqueActions: [PetAction], exitStyle: PetExitStyle, enterStyle: PetEnterStyle) {
        self.physicsMode = physicsMode; self.gravity = gravity; self.canClimbWalls = canClimbWalls
        self.canHangCeiling = canHangCeiling; self.canPassThroughWalls = canPassThroughWalls
        self.baseSpeed = baseSpeed; self.movementStyle = movementStyle
        self.idleDurationRange = idleDurationRange; self.moveDurationRange = moveDurationRange
        self.uniqueActions = uniqueActions; self.exitStyle = exitStyle; self.enterStyle = enterStyle
    }
}

// MARK: - Provider Protocol

public protocol PetBehaviorProvider {
    var profile: PetBehaviorProfile { get }

    func nextBehavior(current: PetAction, physics: PetPhysicsState, level _: PetLevel,
                      elapsed: TimeInterval, foodTarget: CGPoint?,
                      traits: PersonalityTraits) -> PetAction

    func exitSequence(from position: CGPoint, screenBounds: CGRect) -> PetAnimationSequence

    func enterSequence(screenBounds: CGRect) -> PetAnimationSequence

    func chatBehavior(messageFrames: [CGRect], petPosition: CGPoint) -> ChatPetAction?

    func modifyPhysics(_ state: inout PetPhysicsState, deltaTime: CGFloat, surfaces: ScreenSurfaces)
}

// MARK: - Default Implementations

extension PetBehaviorProvider {
    public func nextBehavior(current: PetAction, physics: PetPhysicsState, level _: PetLevel,
                      elapsed: TimeInterval, foodTarget: CGPoint?,
                      traits: PersonalityTraits) -> PetAction {
        // Chase food
        if let target = foodTarget, physics.surface == .ground {
            let dist = hypot(physics.position.x - target.x, physics.position.y - target.y)
            if dist > 8 { return .run }
        }

        // Airborne -> fall (for grounded/bouncing)
        if physics.surface == .airborne
            && profile.physicsMode != .flying {
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

    public func exitSequence(from position: CGPoint, screenBounds: CGRect) -> PetAnimationSequence {
        PetAnimationSequence(steps: [
            PetAnimationStep(action: .walking, duration: 3.0,
                             positionDelta: CGPoint(x: screenBounds.width, y: 0),
                             scaleDelta: nil, opacityDelta: 0.0),
        ])
    }

    public func enterSequence(screenBounds: CGRect) -> PetAnimationSequence {
        PetAnimationSequence(steps: [
            PetAnimationStep(action: .walking, duration: 3.0,
                             positionDelta: CGPoint(x: screenBounds.width / 2,
                                                    y: screenBounds.height - 80),
                             scaleDelta: nil, opacityDelta: 1.0),
        ])
    }

    public func chatBehavior(messageFrames: [CGRect], petPosition: CGPoint) -> ChatPetAction? {
        nil
    }

    public func modifyPhysics(_ state: inout PetPhysicsState, deltaTime: CGFloat, surfaces: ScreenSurfaces) {
        // No modification by default
    }
}
