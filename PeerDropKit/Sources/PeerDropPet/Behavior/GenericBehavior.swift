import CoreGraphics
import Foundation

/// Default behaviour for the expansion families unlocked 2026-06-14 (hamster,
/// fox, pig, totoro, …). They get correct *sprites* immediately; bespoke
/// per-species behaviours (flying owls, slithering snakes) can be added later.
/// A grounded walker that idles, strolls, and occasionally stretches/naps —
/// enough to feel alive without claiming species-specific tricks. Deliberately
/// no wall-climb / ceiling-hang (those read as cat-specific).
public struct GenericBehavior: PetBehaviorProvider {
    public init() {}
    public let profile = PetBehaviorProfile(
        physicsMode: .grounded, gravity: 800,
        canClimbWalls: false, canHangCeiling: false, canPassThroughWalls: false,
        baseSpeed: 60, movementStyle: .walk,
        idleDurationRange: 2.5...5.0, moveDurationRange: 2.0...4.0,
        uniqueActions: [.stretch, .nap],
        exitStyle: .perspectiveWalk, enterStyle: .perspectiveReturn)

    public func nextBehavior(current: PetAction, physics: PetPhysicsState, level _: PetLevel,
                             elapsed: TimeInterval, foodTarget: CGPoint?,
                             traits: PersonalityTraits) -> PetAction {
        // Food chase
        if let target = foodTarget, physics.surface == .ground {
            if hypot(physics.position.x - target.x, physics.position.y - target.y) > 8 { return .run }
        }
        if current == .thrown { return .thrown }
        if physics.surface == .airborne { return .fall }

        // Ground idle → maybe a unique action, a stroll, or keep idling.
        if current == .idle && physics.surface == .ground {
            let idleThreshold = traits.energy > 0.7
                ? profile.idleDurationRange.lowerBound
                : profile.idleDurationRange.upperBound
            if elapsed > idleThreshold {
                let roll = Double.random(in: 0...1)
                if roll < 0.25 {
                    return profile.uniqueActions.randomElement() ?? .idle
                } else if roll < 0.7 {
                    return .walking
                }
                return .idle
            }
        }

        // Walking timeout → idle.
        if current == .walking && physics.surface == .ground {
            if elapsed > profile.moveDurationRange.upperBound { return .idle }
        }

        // Unique-action timeout → idle (so it can't lock forever).
        if profile.uniqueActions.contains(current) && physics.surface == .ground {
            if elapsed > profile.moveDurationRange.upperBound { return .idle }
        }

        return current
    }

    public func exitSequence(from position: CGPoint, screenBounds: CGRect) -> PetAnimationSequence {
        PetAnimationSequence(steps: [
            PetAnimationStep(action: .walking, duration: 3.0,
                             positionDelta: nil, scaleDelta: -0.7, opacityDelta: nil),
        ])
    }

    public func enterSequence(screenBounds: CGRect) -> PetAnimationSequence {
        PetAnimationSequence(steps: [
            PetAnimationStep(action: .walking, duration: 3.0,
                             positionDelta: CGPoint(x: screenBounds.width / 2,
                                                    y: screenBounds.height - 80),
                             scaleDelta: 0.7, opacityDelta: nil),
        ])
    }

    public func chatBehavior(messageFrames: [CGRect], petPosition: CGPoint) -> ChatPetAction? {
        guard !messageFrames.isEmpty else { return nil }
        let index = Int.random(in: 0..<messageFrames.count)
        let action: PetAction = Bool.random() ? .nap : .idle
        return ChatPetAction(targetMessageIndex: index,
                             position: .onTop(offset: -10),
                             action: action,
                             duration: 8.0)
    }
}
