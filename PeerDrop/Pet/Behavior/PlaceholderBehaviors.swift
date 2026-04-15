import Foundation

// MARK: - Placeholder Behavior Implementations
// These provide correct profile values for each species.
// Full behavior logic will be implemented in Task 3.

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
}

struct DogBehavior: PetBehaviorProvider {
    var profile: PetBehaviorProfile {
        PetBehaviorProfile(
            physicsMode: .grounded, gravity: 800,
            canClimbWalls: false, canHangCeiling: false, canPassThroughWalls: false,
            baseSpeed: 80, movementStyle: .walk,
            idleDurationRange: 2.5...5.0, moveDurationRange: 2.0...4.0,
            uniqueActions: [.dig, .fetchToy, .wagTail, .scratchWall],
            exitStyle: .digDown, enterStyle: .digUp)
    }
}

struct RabbitBehavior: PetBehaviorProvider {
    var profile: PetBehaviorProfile {
        PetBehaviorProfile(
            physicsMode: .grounded, gravity: 800,
            canClimbWalls: false, canHangCeiling: false, canPassThroughWalls: false,
            baseSpeed: 75, movementStyle: .hop,
            idleDurationRange: 2.5...5.0, moveDurationRange: 2.0...4.0,
            uniqueActions: [.burrow, .nibble, .alertEars, .binky],
            exitStyle: .digDown, enterStyle: .digUp)
    }
}

struct BirdBehavior: PetBehaviorProvider {
    var profile: PetBehaviorProfile {
        PetBehaviorProfile(
            physicsMode: .flying, gravity: 0,
            canClimbWalls: false, canHangCeiling: false, canPassThroughWalls: false,
            baseSpeed: 90, movementStyle: .fly,
            idleDurationRange: 2.5...5.0, moveDurationRange: 2.0...4.0,
            uniqueActions: [.perch, .peck, .preen, .dive, .glide],
            exitStyle: .flyOff, enterStyle: .flyIn)
    }
}

struct FrogBehavior: PetBehaviorProvider {
    var profile: PetBehaviorProfile {
        PetBehaviorProfile(
            physicsMode: .bouncing, gravity: 800,
            canClimbWalls: true, canHangCeiling: true, canPassThroughWalls: false,
            baseSpeed: 60, movementStyle: .hop,
            idleDurationRange: 2.5...5.0, moveDurationRange: 2.0...4.0,
            uniqueActions: [.tongueSnap, .croak, .swim, .stickyWall],
            exitStyle: .hopOff, enterStyle: .hopIn)
    }
}

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
}

struct DragonBehavior: PetBehaviorProvider {
    var profile: PetBehaviorProfile {
        PetBehaviorProfile(
            physicsMode: .flying, gravity: 0,
            canClimbWalls: false, canHangCeiling: false, canPassThroughWalls: false,
            baseSpeed: 100, movementStyle: .fly,
            idleDurationRange: 2.5...5.0, moveDurationRange: 2.0...4.0,
            uniqueActions: [.breathFire, .hover, .wingSpread, .roar],
            exitStyle: .skyAscend, enterStyle: .skyDescend)
    }
}

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
}

struct GhostBehavior: PetBehaviorProvider {
    var profile: PetBehaviorProfile {
        PetBehaviorProfile(
            physicsMode: .floating, gravity: 0,
            canClimbWalls: false, canHangCeiling: false, canPassThroughWalls: true,
            baseSpeed: 55, movementStyle: .float,
            idleDurationRange: 2.5...5.0, moveDurationRange: 2.0...4.0,
            uniqueActions: [.phaseThrough, .flicker, .spook, .vanish],
            exitStyle: .fadeOut, enterStyle: .fadeIn)
    }
}

struct SlimeBehavior: PetBehaviorProvider {
    var profile: PetBehaviorProfile {
        PetBehaviorProfile(
            physicsMode: .bouncing, gravity: 600,
            canClimbWalls: false, canHangCeiling: false, canPassThroughWalls: false,
            baseSpeed: 40, movementStyle: .bounce,
            idleDurationRange: 2.5...5.0, moveDurationRange: 2.0...4.0,
            uniqueActions: [.split, .melt, .absorb, .wallStick],
            exitStyle: .meltDown, enterStyle: .reformUp)
    }
}
