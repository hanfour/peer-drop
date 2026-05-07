import CoreGraphics
import Foundation

struct BirdBehavior: PetBehaviorProvider {
    let profile = PetBehaviorProfile(
            physicsMode: .flying, gravity: 0,
            canClimbWalls: false, canHangCeiling: false, canPassThroughWalls: false,
            baseSpeed: 90, movementStyle: .fly,
            idleDurationRange: 2.5...5.0, moveDurationRange: 2.0...4.0,
            uniqueActions: [.perch, .peck, .preen, .dive, .glide],
            exitStyle: .flyOff, enterStyle: .flyIn)

    func nextBehavior(current: PetAction, physics: PetPhysicsState, level: PetLevel,
                      elapsed: TimeInterval, foodTarget: CGPoint?,
                      traits: PersonalityTraits) -> PetAction {
        // Food chase
        if let target = foodTarget, physics.surface == .ground {
            if hypot(physics.position.x - target.x, physics.position.y - target.y) > 8 { return .run }
        }

        // Thrown
        if current == .thrown { return .thrown }

        // IMPORTANT: Bird NEVER falls — override airborne to glide/hover
        if physics.surface == .airborne {
            if current == .glide && elapsed > 3.0 {
                return .dive
            }
            if current == .dive && elapsed > 1.5 {
                return .glide
            }
            if current == .idle || current == .fall {
                return Bool.random() ? .glide : .hover
            }
            return current
        }

        // Ground behavior — peck/preen then take off
        if physics.surface == .ground {
            if current == .idle && elapsed > profile.idleDurationRange.lowerBound {
                let roll = Double.random(in: 0...1)
                if roll < 0.3 {
                    return [.peck, .preen].randomElement() ?? .peck
                } else if roll < 0.6 {
                    return .glide  // take off
                }
                return .walking
            }
            if (current == .peck || current == .preen) && elapsed > 2.0 {
                return .glide  // take off after ground action
            }
        }

        // Perch on surfaces briefly
        if physics.surface == .leftWall || physics.surface == .rightWall
            || physics.surface == .ceiling || physics.surface == .dynamicIsland {
            if current == .perch && elapsed > 3.0 {
                return .glide  // fly away
            }
            return .perch
        }

        // Walking timeout
        if current == .walking && physics.surface == .ground {
            if elapsed > profile.moveDurationRange.upperBound { return .idle }
        }

        return current
    }

    func exitSequence(from position: CGPoint, screenBounds: CGRect) -> PetAnimationSequence {
        // Glide toward nearest edge
        let toRight = position.x < screenBounds.midX
        let edgeDeltaX = toRight ? screenBounds.maxX - position.x + 50
                                  : -(position.x - screenBounds.minX + 50)
        return PetAnimationSequence(steps: [
            PetAnimationStep(action: .glide, duration: 2.0,
                             positionDelta: CGPoint(x: edgeDeltaX, y: -30),
                             scaleDelta: nil,
                             opacityDelta: nil),
        ])
    }

    func enterSequence(screenBounds: CGRect) -> PetAnimationSequence {
        PetAnimationSequence(steps: [
            PetAnimationStep(action: .glide, duration: 2.0,
                             positionDelta: CGPoint(x: screenBounds.width / 2,
                                                    y: screenBounds.height / 3),
                             scaleDelta: nil,
                             opacityDelta: 1.0),
        ])
    }

    func chatBehavior(messageFrames: [CGRect], petPosition: CGPoint) -> ChatPetAction? {
        guard !messageFrames.isEmpty else { return nil }
        let index = Int.random(in: 0..<messageFrames.count)
        let useOnTop = Bool.random()
        let position: ChatPetPosition = useOnTop
            ? .onTop(offset: -5)
            : .above(height: 20)
        let action: PetAction = useOnTop ? .perch : .preen
        return ChatPetAction(targetMessageIndex: index,
                             position: position,
                             action: action,
                             duration: 6.0)
    }
}
