import CoreGraphics
import Foundation

struct OctopusBehavior: PetBehaviorProvider {
    var profile: PetBehaviorProfile {
        PetBehaviorProfile(
            physicsMode: .crawling, gravity: 400,
            canClimbWalls: true, canHangCeiling: true, canPassThroughWalls: false,
            baseSpeed: 50, movementStyle: .slither,
            idleDurationRange: 2.5...5.0, moveDurationRange: 2.0...4.0,
            uniqueActions: [.inkSquirt, .tentacleReach, .camouflage, .wallSuction],
            exitStyle: .inkVanish, enterStyle: .inkAppear)
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

        // Airborne -> fall (crawling mode has reduced gravity)
        if physics.surface == .airborne { return .fall }

        // Wall: wallSuction or camouflage
        if physics.surface == .leftWall || physics.surface == .rightWall {
            if current == .wallSuction && elapsed > 3.0 {
                return Bool.random() ? .camouflage : .idle
            }
            if current == .camouflage && elapsed > 4.0 {
                return .idle
            }
            return .wallSuction
        }

        // Ceiling: wallSuction
        if physics.surface == .ceiling {
            if current == .wallSuction && elapsed > 3.0 {
                return .fall
            }
            return .wallSuction
        }

        // Ground idle
        if current == .idle && physics.surface == .ground {
            let idleThreshold = traits.energy > 0.7
                ? profile.idleDurationRange.lowerBound
                : profile.idleDurationRange.upperBound
            if elapsed > idleThreshold {
                let roll = Double.random(in: 0...1)
                if roll < 0.2 {
                    return .inkSquirt
                } else if roll < 0.4 {
                    return .tentacleReach
                } else if roll < 0.7 {
                    return .walking
                }
                return .idle
            }
        }

        // Species action timeout
        if (current == .inkSquirt || current == .tentacleReach) && elapsed > 2.0 {
            return .idle
        }

        // Walking timeout
        if current == .walking && physics.surface == .ground {
            if elapsed > profile.moveDurationRange.upperBound { return .idle }
        }

        return current
    }

    func exitSequence(from position: CGPoint, screenBounds: CGRect) -> PetAnimationSequence {
        PetAnimationSequence(steps: [
            PetAnimationStep(action: .inkSquirt, duration: 1.0,
                             positionDelta: nil,
                             scaleDelta: nil,
                             opacityDelta: nil),
            PetAnimationStep(action: .idle, duration: 1.5,
                             positionDelta: nil,
                             scaleDelta: nil,
                             opacityDelta: -1.0),
        ])
    }

    func enterSequence(screenBounds: CGRect) -> PetAnimationSequence {
        PetAnimationSequence(steps: [
            PetAnimationStep(action: .idle, duration: 1.5,
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
                             position: .wrappedAround,
                             action: .tentacleReach,
                             duration: 7.0)
    }
}
