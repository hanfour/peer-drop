import CoreGraphics
import Foundation

final class GhostBehavior: PetBehaviorProvider {
    let profile = PetBehaviorProfile(
            physicsMode: .floating, gravity: 0,
            canClimbWalls: false, canHangCeiling: false, canPassThroughWalls: true,
            baseSpeed: 55, movementStyle: .float,
            idleDurationRange: 2.5...5.0, moveDurationRange: 2.0...4.0,
            uniqueActions: [.phaseThrough, .flicker, .spook, .vanish],
            exitStyle: .fadeOut, enterStyle: .fadeIn)

    // Phase 2 of v4.0.2 ghost fix: timestamp-gated flicker/vanish so users see
    // ghost-specific behavior within 1–2 minutes instead of waiting 30–60s
    // for the exit/return cycle.
    private var lastFlickerAt: Date = .distantPast
    private var lastVanishAt: Date = .distantPast

    init() {}

    func nextBehavior(current: PetAction, physics: PetPhysicsState, level _: PetLevel,
                      elapsed: TimeInterval, foodTarget: CGPoint?,
                      traits: PersonalityTraits) -> PetAction {
        // Food chase
        if let target = foodTarget, physics.surface == .ground {
            if hypot(physics.position.x - target.x, physics.position.y - target.y) > 8 { return .run }
        }

        // Thrown
        if current == .thrown { return .thrown }

        // IMPORTANT: Ghost NEVER falls — floating is normal state
        // Airborne is the ghost's natural habitat
        if physics.surface == .airborne || physics.surface == .ground {
            // Periodic flicker — every 15-30s when idle (independent of long
            // idle gate). Gives users visible ghost-specific behavior fast.
            let now = Date()
            if current == .idle && elapsed > 2.0 {
                let flickerCooldown = TimeInterval.random(in: 15...30)
                if now.timeIntervalSince(lastFlickerAt) > flickerCooldown {
                    lastFlickerAt = now
                    return .flicker
                }
                // Periodic vanish — every 2-3 minutes when idle.
                let vanishCooldown = TimeInterval.random(in: 120...180)
                if now.timeIntervalSince(lastVanishAt) > vanishCooldown {
                    lastVanishAt = now
                    return .vanish
                }
            }

            if current == .idle && elapsed > profile.idleDurationRange.lowerBound {
                // Long-idle path: pick from the broader species action set.
                // Skews toward .phaseThrough (movement) so ghost still drifts
                // around the screen between flicker/vanish bursts.
                let speciesActions: [PetAction] = [.phaseThrough, .phaseThrough,
                                                   .flicker, .spook, .vanish]
                let pick = speciesActions.randomElement() ?? .idle
                if pick == .flicker { lastFlickerAt = Date() }
                if pick == .vanish { lastVanishAt = Date() }
                return pick
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
