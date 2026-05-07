import CoreGraphics
import Foundation

struct DogBehavior: PetBehaviorProvider {
    let profile = PetBehaviorProfile(
            physicsMode: .grounded, gravity: 800,
            canClimbWalls: false, canHangCeiling: false, canPassThroughWalls: false,
            baseSpeed: 80, movementStyle: .walk,
            idleDurationRange: 2.5...5.0, moveDurationRange: 2.0...4.0,
            uniqueActions: [.dig, .fetchToy, .wagTail, .scratchWall],
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

        // Near wall -> scratch wall
        if physics.surface == .leftWall || physics.surface == .rightWall {
            return .scratchWall
        }

        // Ground idle
        if current == .idle && physics.surface == .ground {
            let idleThreshold = traits.energy > 0.7
                ? profile.idleDurationRange.lowerBound
                : profile.idleDurationRange.upperBound
            if elapsed > idleThreshold {
                let roll = Double.random(in: 0...1)
                if roll < 0.3 {
                    let speciesActions: [PetAction] = [.dig, .fetchToy, .wagTail, .scratchWall]
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
            PetAnimationStep(action: .dig, duration: 2.0,
                             positionDelta: nil,
                             scaleDelta: nil,
                             opacityDelta: -1.0),   // fade out while digging
        ])
    }

    func enterSequence(screenBounds: CGRect) -> PetAnimationSequence {
        PetAnimationSequence(steps: [
            PetAnimationStep(action: .idle, duration: 1.5,
                             positionDelta: CGPoint(x: screenBounds.width / 2,
                                                    y: screenBounds.height - 80),
                             scaleDelta: nil,
                             opacityDelta: 1.0),    // emerge from ground
        ])
    }

    func chatBehavior(messageFrames: [CGRect], petPosition: CGPoint) -> ChatPetAction? {
        guard !messageFrames.isEmpty else { return nil }
        let index = Int.random(in: 0..<messageFrames.count)
        return ChatPetAction(targetMessageIndex: index,
                             position: .beside(leading: Bool.random()),
                             action: .idle,
                             duration: 6.0)
    }
}
