import CoreGraphics
import Foundation

struct RabbitBehavior: PetBehaviorProvider {
    let profile = PetBehaviorProfile(
            physicsMode: .grounded, gravity: 800,
            canClimbWalls: false, canHangCeiling: false, canPassThroughWalls: false,
            baseSpeed: 75, movementStyle: .hop,
            idleDurationRange: 2.5...5.0, moveDurationRange: 2.0...4.0,
            uniqueActions: [.burrow, .nibble, .alertEars, .binky],
            exitStyle: .digDown, enterStyle: .digUp)

    func nextBehavior(current: PetAction, physics: PetPhysicsState, level _: PetLevel,
                      elapsed: TimeInterval, foodTarget: CGPoint?,
                      traits: PersonalityTraits) -> PetAction {
        // Food chase
        if let target = foodTarget, physics.surface == .ground {
            if hypot(physics.position.x - target.x, physics.position.y - target.y) > 8 { return .run }
        }

        // Thrown
        if current == .thrown { return .thrown }

        // Airborne -> fall
        if physics.surface == .airborne { return .fall }

        // Ground idle
        if current == .idle && physics.surface == .ground {
            let idleThreshold = traits.energy > 0.7
                ? profile.idleDurationRange.lowerBound
                : profile.idleDurationRange.upperBound
            if elapsed > idleThreshold {
                let roll = Double.random(in: 0...1)
                if roll < 0.3 {
                    let speciesActions: [PetAction] = [.nibble, .alertEars, .binky]
                    return speciesActions.randomElement() ?? .idle
                } else if roll < 0.7 {
                    return .walking
                }
                return .idle
            }
        }

        // Walking timeout
        if current == .walking && physics.surface == .ground {
            if elapsed > profile.moveDurationRange.upperBound { return .idle }
        }

        return current
    }

    func exitSequence(from position: CGPoint, screenBounds: CGRect) -> PetAnimationSequence {
        PetAnimationSequence(steps: [
            PetAnimationStep(action: .burrow, duration: 1.5,
                             positionDelta: nil,
                             scaleDelta: nil,
                             opacityDelta: -1.0),
        ])
    }

    func enterSequence(screenBounds: CGRect) -> PetAnimationSequence {
        PetAnimationSequence(steps: [
            PetAnimationStep(action: .binky, duration: 1.0,
                             positionDelta: CGPoint(x: screenBounds.width / 2,
                                                    y: screenBounds.height - 80),
                             scaleDelta: nil,
                             opacityDelta: 1.0),
        ])
    }

    func chatBehavior(messageFrames: [CGRect], petPosition: CGPoint) -> ChatPetAction? {
        guard messageFrames.count >= 2 else { return nil }
        let upperIndex = Int.random(in: 0..<messageFrames.count - 1)
        return ChatPetAction(targetMessageIndex: upperIndex,
                             position: .between(upperIndex: upperIndex),
                             action: .binky,
                             duration: 4.0)
    }
}
