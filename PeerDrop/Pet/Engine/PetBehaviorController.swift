import CoreGraphics
import Foundation

enum PetBehaviorController {

    static func nextBehavior(current: PetAction, physics: PetPhysicsState,
                             level: PetLevel, elapsed: TimeInterval,
                             foodTarget: CGPoint? = nil,
                             traits: PersonalityTraits? = nil) -> PetAction {
        guard level != .egg else { return .idle }

        if let target = foodTarget, physics.surface == .ground {
            let dist = hypot(physics.position.x - target.x, physics.position.y - target.y)
            if dist > 8 { return .run }
        }

        switch (current, physics.surface) {
        case (.idle, .ground):
            if elapsed > 5 { return Bool.random() ? .walking : .idle }
            return .idle

        case (.walking, .ground):
            if elapsed > 4 { return .idle }
            return .walking

        case (.walking, .leftWall), (.walking, .rightWall):
            return Bool.random() ? .climb : .walking

        case (.climb, .leftWall), (.climb, .rightWall):
            if elapsed > 3 { return Bool.random() ? .fall : .hang }
            return .climb

        case (.climb, .ceiling):
            return .hang

        case (.hang, .ceiling):
            if elapsed > 3 {
                let roll = Double.random(in: 0...1)
                if roll < 0.3 { return .fall }
                if roll < 0.6 { return .sitEdge }
                return .hang
            }
            return .hang

        case (.sitEdge, .ceiling):
            if elapsed > 8 { return .fall }
            return .sitEdge

        case (.fall, _):
            return .fall

        case (.thrown, _):
            return .thrown

        case (_, .airborne):
            return .fall

        default:
            return current
        }
    }
}
