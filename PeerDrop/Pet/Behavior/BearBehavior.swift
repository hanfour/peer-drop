import CoreGraphics
import Foundation

struct BearBehavior: PetBehaviorProvider {
    var profile: PetBehaviorProfile {
        PetBehaviorProfile(
            physicsMode: .grounded, gravity: 800,
            canClimbWalls: false, canHangCeiling: false, canPassThroughWalls: false,
            baseSpeed: 45, movementStyle: .walk,
            idleDurationRange: 2.5...5.0, moveDurationRange: 2.0...4.0,
            uniqueActions: [.backScratch, .standUp, .pawSlam, .bigYawn],
            exitStyle: .walkOff, enterStyle: .walkIn)
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

        // Airborne -> fall
        if physics.surface == .airborne { return .fall }

        // Near wall -> backScratch
        if physics.surface == .leftWall || physics.surface == .rightWall {
            if current == .backScratch && elapsed > 3.0 {
                return .idle
            }
            return .backScratch
        }

        // Ground idle — long durations, slow bear
        if current == .idle && physics.surface == .ground {
            // Bears have longer idle thresholds
            let idleThreshold = traits.energy > 0.7
                ? profile.idleDurationRange.upperBound
                : profile.idleDurationRange.upperBound + 2.0
            if elapsed > idleThreshold {
                let roll = Double.random(in: 0...1)
                if roll < 0.3 {
                    let speciesActions: [PetAction] = [.backScratch, .standUp, .pawSlam, .bigYawn]
                    return speciesActions.randomElement() ?? .idle
                } else if roll < 0.7 {
                    return .walking  // slow walk
                }
                return .idle
            }
        }

        // Species action timeout
        if [.backScratch, .standUp, .pawSlam, .bigYawn].contains(current) && elapsed > 3.0 {
            return .idle
        }

        // Walking timeout
        if current == .walking && physics.surface == .ground {
            if elapsed > profile.moveDurationRange.upperBound { return .idle }
        }

        return current
    }

    func exitSequence(from position: CGPoint, screenBounds: CGRect) -> PetAnimationSequence {
        let edgeDeltaX = position.x < screenBounds.midX
            ? -(position.x + 50)
            : (screenBounds.maxX - position.x + 50)
        return PetAnimationSequence(steps: [
            PetAnimationStep(action: .walking, duration: 4.0,
                             positionDelta: CGPoint(x: edgeDeltaX, y: 0),
                             scaleDelta: nil,
                             opacityDelta: nil),
        ])
    }

    func enterSequence(screenBounds: CGRect) -> PetAnimationSequence {
        PetAnimationSequence(steps: [
            PetAnimationStep(action: .walking, duration: 4.0,
                             positionDelta: CGPoint(x: screenBounds.width / 2,
                                                    y: screenBounds.height - 80),
                             scaleDelta: nil,
                             opacityDelta: 1.0),
        ])
    }

    func chatBehavior(messageFrames: [CGRect], petPosition: CGPoint) -> ChatPetAction? {
        guard !messageFrames.isEmpty else { return nil }
        let index = Int.random(in: 0..<messageFrames.count)
        let action: PetAction = Bool.random() ? .sleeping : .bigYawn
        return ChatPetAction(targetMessageIndex: index,
                             position: .leaningOn(leading: Bool.random()),
                             action: action,
                             duration: 10.0)
    }
}
