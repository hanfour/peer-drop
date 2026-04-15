import CoreGraphics
import Foundation

struct CatBehavior: PetBehaviorProvider {
    var profile: PetBehaviorProfile {
        PetBehaviorProfile(
            physicsMode: .grounded, gravity: 800,
            canClimbWalls: true, canHangCeiling: true, canPassThroughWalls: false,
            baseSpeed: 70, movementStyle: .walk,
            idleDurationRange: 2.5...5.0, moveDurationRange: 2.0...4.0,
            uniqueActions: [.scratch, .stretch, .groom, .nap],
            exitStyle: .perspectiveWalk, enterStyle: .perspectiveReturn)
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

        // Wall climbing
        if physics.surface == .leftWall || physics.surface == .rightWall {
            let climbChance = 0.5 + traits.mischief * 0.25 // 50-75%
            if current == .climb {
                // After 3s on wall, decide next
                if elapsed > 3.0 {
                    return Bool.random() ? .hang : .fall
                }
                return .climb
            }
            if Double.random(in: 0...1) < climbChance {
                return .climb
            }
            return .walking
        }

        // Ceiling hang
        if physics.surface == .ceiling {
            if current == .hang && elapsed > 3.0 {
                let roll = Double.random(in: 0...1)
                if roll < 0.3 { return .fall }
                if roll < 0.6 { return .sitEdge }
                return .hang
            }
            return .hang
        }

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
                    // Species-specific action
                    let speciesActions: [PetAction] = [.scratch, .stretch, .groom, .nap]
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
            PetAnimationStep(action: .walking, duration: 3.0,
                             positionDelta: nil,
                             scaleDelta: -0.7,    // 1.0 -> 0.3
                             opacityDelta: nil),
        ])
    }

    func enterSequence(screenBounds: CGRect) -> PetAnimationSequence {
        PetAnimationSequence(steps: [
            PetAnimationStep(action: .walking, duration: 3.0,
                             positionDelta: CGPoint(x: screenBounds.width / 2,
                                                    y: screenBounds.height - 80),
                             scaleDelta: 0.7,     // 0.3 -> 1.0
                             opacityDelta: nil),
        ])
    }

    func chatBehavior(messageFrames: [CGRect], petPosition: CGPoint) -> ChatPetAction? {
        guard !messageFrames.isEmpty else { return nil }
        let index = Int.random(in: 0..<messageFrames.count)
        let action: PetAction = Bool.random() ? .nap : .idle
        return ChatPetAction(targetMessageIndex: index,
                             position: .onTop(offset: -10),
                             action: action,
                             duration: 8.0)
    }
}
