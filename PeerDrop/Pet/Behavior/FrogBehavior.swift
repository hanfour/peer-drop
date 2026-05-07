import CoreGraphics
import Foundation

struct FrogBehavior: PetBehaviorProvider {
    let profile = PetBehaviorProfile(
            physicsMode: .bouncing, gravity: 800,
            canClimbWalls: true, canHangCeiling: true, canPassThroughWalls: false,
            baseSpeed: 60, movementStyle: .hop,
            idleDurationRange: 2.5...5.0, moveDurationRange: 2.0...4.0,
            uniqueActions: [.tongueSnap, .croak, .swim, .stickyWall],
            exitStyle: .hopOff, enterStyle: .hopIn)

    func nextBehavior(current: PetAction, physics: PetPhysicsState, level: PetLevel,
                      elapsed: TimeInterval, foodTarget: CGPoint?,
                      traits: PersonalityTraits) -> PetAction {
        // Food chase
        if let target = foodTarget, physics.surface == .ground {
            if hypot(physics.position.x - target.x, physics.position.y - target.y) > 8 { return .run }
        }

        // Thrown
        if current == .thrown { return .thrown }

        // Airborne -> fall (bouncing mode, will bounce on landing)
        if physics.surface == .airborne { return .fall }

        // Wall: stickyWall
        if physics.surface == .leftWall || physics.surface == .rightWall {
            if current == .stickyWall && elapsed > 3.0 {
                return .jump  // hop off wall
            }
            return .stickyWall
        }

        // Ceiling: stickyWall
        if physics.surface == .ceiling {
            if current == .stickyWall && elapsed > 2.0 {
                return .fall
            }
            return .stickyWall
        }

        // Ground idle
        if current == .idle && physics.surface == .ground {
            let idleThreshold = traits.energy > 0.7
                ? profile.idleDurationRange.lowerBound
                : profile.idleDurationRange.upperBound
            if elapsed > idleThreshold {
                let roll = Double.random(in: 0...1)
                if roll < 0.2 {
                    return .tongueSnap
                } else if roll < 0.35 {
                    return .croak
                } else {
                    return .jump  // movement is always hop/jump
                }
            }
        }

        // After species action, return to idle
        if (current == .tongueSnap || current == .croak) && elapsed > 1.5 {
            return .idle
        }

        // Jump timeout -> idle
        if current == .jump && physics.surface == .ground && elapsed > 1.0 {
            return .idle
        }

        return current
    }

    func exitSequence(from position: CGPoint, screenBounds: CGRect) -> PetAnimationSequence {
        PetAnimationSequence(steps: [
            PetAnimationStep(action: .jump, duration: 0.6,
                             positionDelta: CGPoint(x: 40, y: -30),
                             scaleDelta: nil, opacityDelta: nil),
            PetAnimationStep(action: .jump, duration: 0.6,
                             positionDelta: CGPoint(x: 60, y: -50),
                             scaleDelta: nil, opacityDelta: nil),
            PetAnimationStep(action: .jump, duration: 0.8,
                             positionDelta: CGPoint(x: screenBounds.width, y: -80),
                             scaleDelta: nil, opacityDelta: -1.0),
        ])
    }

    func enterSequence(screenBounds: CGRect) -> PetAnimationSequence {
        PetAnimationSequence(steps: [
            PetAnimationStep(action: .jump, duration: 1.0,
                             positionDelta: CGPoint(x: screenBounds.width / 2,
                                                    y: screenBounds.height - 80),
                             scaleDelta: nil,
                             opacityDelta: 1.0),
        ])
    }

    func chatBehavior(messageFrames: [CGRect], petPosition: CGPoint) -> ChatPetAction? {
        guard !messageFrames.isEmpty else { return nil }
        let index = Int.random(in: 0..<messageFrames.count)
        return ChatPetAction(targetMessageIndex: index,
                             position: .stickedOn(leading: Bool.random()),
                             action: .stickyWall,
                             duration: 5.0)
    }
}
