import CoreGraphics
import Foundation

struct DragonBehavior: PetBehaviorProvider {
    let profile = PetBehaviorProfile(
            physicsMode: .flying, gravity: 0,
            canClimbWalls: false, canHangCeiling: false, canPassThroughWalls: false,
            baseSpeed: 100, movementStyle: .fly,
            idleDurationRange: 2.5...5.0, moveDurationRange: 2.0...4.0,
            uniqueActions: [.breathFire, .hover, .wingSpread, .roar],
            exitStyle: .skyAscend, enterStyle: .skyDescend)

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

        // IMPORTANT: Dragon NEVER falls — override airborne
        if physics.surface == .airborne {
            if current == .idle || current == .fall {
                return .hover
            }
            if current == .hover && elapsed > 3.0 {
                let roll = Double.random(in: 0...1)
                if roll < 0.3 { return .breathFire }
                if roll < 0.5 { return .wingSpread }
                return .hover
            }
            if current == .breathFire && elapsed > 2.0 {
                return .hover
            }
            if current == .wingSpread && elapsed > 2.0 {
                return .hover
            }
            return current
        }

        // Ground: roar then take off
        if physics.surface == .ground {
            if current == .idle && elapsed > profile.idleDurationRange.lowerBound {
                return .roar
            }
            if current == .roar && elapsed > 2.0 {
                return .hover  // take off
            }
            if current == .walking && elapsed > profile.moveDurationRange.upperBound {
                return .idle
            }
        }

        return current
    }

    func exitSequence(from position: CGPoint, screenBounds: CGRect) -> PetAnimationSequence {
        PetAnimationSequence(steps: [
            PetAnimationStep(action: .wingSpread, duration: 1.0,
                             positionDelta: nil,
                             scaleDelta: nil,
                             opacityDelta: nil),
            PetAnimationStep(action: .hover, duration: 2.0,
                             positionDelta: CGPoint(x: 0, y: -screenBounds.height),
                             scaleDelta: nil,
                             opacityDelta: nil),
        ])
    }

    func enterSequence(screenBounds: CGRect) -> PetAnimationSequence {
        PetAnimationSequence(steps: [
            PetAnimationStep(action: .dive, duration: 2.0,
                             positionDelta: CGPoint(x: screenBounds.width / 2,
                                                    y: screenBounds.height / 2),
                             scaleDelta: nil,
                             opacityDelta: 1.0),
        ])
    }

    func chatBehavior(messageFrames: [CGRect], petPosition: CGPoint) -> ChatPetAction? {
        guard !messageFrames.isEmpty else { return nil }
        let index = Int.random(in: 0..<messageFrames.count)
        return ChatPetAction(targetMessageIndex: index,
                             position: .coiled,
                             action: .hover,
                             duration: 8.0)
    }
}
