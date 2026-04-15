import CoreGraphics
import Foundation

struct GhostBehavior: PetBehaviorProvider {
    let profile = PetBehaviorProfile(
            physicsMode: .floating, gravity: 0,
            canClimbWalls: false, canHangCeiling: false, canPassThroughWalls: true,
            baseSpeed: 55, movementStyle: .float,
            idleDurationRange: 2.5...5.0, moveDurationRange: 2.0...4.0,
            uniqueActions: [.phaseThrough, .flicker, .spook, .vanish],
            exitStyle: .fadeOut, enterStyle: .fadeIn)

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

        // IMPORTANT: Ghost NEVER falls — floating is normal state
        // Airborne is the ghost's natural habitat
        if physics.surface == .airborne || physics.surface == .ground {
            if current == .idle && elapsed > profile.idleDurationRange.lowerBound {
                let speciesActions: [PetAction] = [.phaseThrough, .flicker, .spook, .vanish]
                return speciesActions.randomElement() ?? .idle
            }

            // After species action, return to floating idle
            if [.phaseThrough, .flicker, .spook, .vanish].contains(current) && elapsed > 2.5 {
                return .idle
            }
        }

        // Ghost can float freely on any surface — never fall
        if current == .fall {
            return .idle
        }

        return current
    }

    func exitSequence(from position: CGPoint, screenBounds: CGRect) -> PetAnimationSequence {
        PetAnimationSequence(steps: [
            PetAnimationStep(action: .flicker, duration: 2.0,
                             positionDelta: nil,
                             scaleDelta: nil,
                             opacityDelta: nil),
            PetAnimationStep(action: .idle, duration: 1.0,
                             positionDelta: nil,
                             scaleDelta: nil,
                             opacityDelta: -1.0),  // 1.0 -> 0.0
        ])
    }

    func enterSequence(screenBounds: CGRect) -> PetAnimationSequence {
        PetAnimationSequence(steps: [
            PetAnimationStep(action: .idle, duration: 1.0,
                             positionDelta: CGPoint(x: screenBounds.width / 2,
                                                    y: screenBounds.height / 2),
                             scaleDelta: nil,
                             opacityDelta: 0.5),   // 0 -> 0.5
            PetAnimationStep(action: .idle, duration: 1.0,
                             positionDelta: nil,
                             scaleDelta: nil,
                             opacityDelta: 0.5),   // 0.5 -> 1.0
        ])
    }

    func chatBehavior(messageFrames: [CGRect], petPosition: CGPoint) -> ChatPetAction? {
        guard !messageFrames.isEmpty else { return nil }
        let index = Int.random(in: 0..<messageFrames.count)
        return ChatPetAction(targetMessageIndex: index,
                             position: .behind,
                             action: .spook,
                             duration: 5.0)
    }
}
