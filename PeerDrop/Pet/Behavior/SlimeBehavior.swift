import CoreGraphics
import Foundation

struct SlimeBehavior: PetBehaviorProvider {
    var profile: PetBehaviorProfile {
        PetBehaviorProfile(
            physicsMode: .bouncing, gravity: 600,
            canClimbWalls: false, canHangCeiling: false, canPassThroughWalls: false,
            baseSpeed: 40, movementStyle: .bounce,
            idleDurationRange: 2.5...5.0, moveDurationRange: 2.0...4.0,
            uniqueActions: [.split, .melt, .absorb, .wallStick],
            exitStyle: .meltDown, enterStyle: .reformUp)
    }

    func nextBehavior(current: PetAction, physics: PetPhysicsState, level: PetLevel,
                      elapsed: TimeInterval, foodTarget: CGPoint?,
                      traits: PersonalityTraits) -> PetAction {
        guard level != .egg else { return .idle }

        // Food chase
        if let target = foodTarget, physics.surface == .ground {
            if hypot(physics.position.x - target.x, physics.position.y - target.y) > 8 { return .run }
        }

        // Thrown
        if current == .thrown { return .thrown }

        // Airborne -> fall (bouncing mode, will bounce on landing)
        if physics.surface == .airborne { return .fall }

        // Near wall after landing -> wallStick
        if physics.surface == .leftWall || physics.surface == .rightWall {
            if current == .wallStick && elapsed > 2.0 {
                return .fall  // unstick and fall
            }
            return .wallStick
        }

        // Ground idle
        if current == .idle && physics.surface == .ground {
            let idleThreshold = traits.energy > 0.7
                ? profile.idleDurationRange.lowerBound
                : profile.idleDurationRange.upperBound
            if elapsed > idleThreshold {
                let roll = Double.random(in: 0...1)
                if roll < 0.2 {
                    return .split
                } else if roll < 0.35 {
                    return .melt
                } else if roll < 0.45 {
                    return .absorb
                } else {
                    return .jump  // movement via bounce
                }
            }
        }

        // Species action timeout
        if [.split, .melt, .absorb].contains(current) && elapsed > 2.0 {
            return .idle
        }

        // Bounce timeout -> idle
        if current == .jump && physics.surface == .ground && elapsed > 1.0 {
            return .idle
        }

        return current
    }

    func exitSequence(from position: CGPoint, screenBounds: CGRect) -> PetAnimationSequence {
        PetAnimationSequence(steps: [
            PetAnimationStep(action: .melt, duration: 2.0,
                             positionDelta: nil,
                             scaleDelta: nil,
                             opacityDelta: -1.0),
        ])
    }

    func enterSequence(screenBounds: CGRect) -> PetAnimationSequence {
        PetAnimationSequence(steps: [
            PetAnimationStep(action: .idle, duration: 2.0,
                             positionDelta: CGPoint(x: screenBounds.width / 2,
                                                    y: screenBounds.height - 80),
                             scaleDelta: nil,
                             opacityDelta: 1.0),   // reform
        ])
    }

    func chatBehavior(messageFrames: [CGRect], petPosition: CGPoint) -> ChatPetAction? {
        guard !messageFrames.isEmpty else { return nil }
        let index = Int.random(in: 0..<messageFrames.count)
        return ChatPetAction(targetMessageIndex: index,
                             position: .dripping,
                             action: .melt,
                             duration: 6.0)
    }
}
