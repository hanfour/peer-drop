import Foundation

enum SpriteDataRegistry {
    static func sprites(for body: BodyGene, stage: PetLevel) -> [PetAction: [[[UInt8]]]]? {
        switch stage {
        case .egg: return nil
        case .baby: return babySprites(for: body)
        case .child: return childSprites(for: body)
        }
    }

    static func meta(for body: BodyGene) -> BodyMeta {
        switch body {
        case .cat: return CatSpriteData.meta
        case .dog: return DogSpriteData.meta
        case .rabbit: return RabbitSpriteData.meta
        case .bird: return BirdSpriteData.meta
        case .frog: return FrogSpriteData.meta
        case .bear: return BearSpriteData.meta
        case .dragon: return DragonSpriteData.meta
        case .octopus: return OctopusSpriteData.meta
        case .ghost: return GhostSpriteData.meta
        case .slime: return SlimeSpriteData.meta
        }
    }

    static func frameCount(for body: BodyGene, stage: PetLevel, action: PetAction) -> Int {
        if let sprites = sprites(for: body, stage: stage),
           let frames = sprites[action] {
            return frames.count
        }
        // Fallback: use idle frames for unimplemented species actions
        if let sprites = sprites(for: body, stage: stage),
           let idleFrames = sprites[.idle] {
            return idleFrames.count
        }
        return 1
    }

    /// Returns the action to use for rendering — falls back to .idle if no sprite exists
    static func resolvedAction(for body: BodyGene, stage: PetLevel, action: PetAction) -> PetAction {
        if let sprites = sprites(for: body, stage: stage),
           sprites[action] != nil {
            return action
        }
        return .idle
    }

    private static func babySprites(for body: BodyGene) -> [PetAction: [[[UInt8]]]] {
        switch body {
        case .cat: return CatSpriteData.baby
        case .dog: return DogSpriteData.baby
        case .rabbit: return RabbitSpriteData.baby
        case .bird: return BirdSpriteData.baby
        case .frog: return FrogSpriteData.baby
        case .bear: return BearSpriteData.baby
        case .dragon: return DragonSpriteData.baby
        case .octopus: return OctopusSpriteData.baby
        case .ghost: return GhostSpriteData.baby
        case .slime: return SlimeSpriteData.baby
        }
    }

    private static func childSprites(for body: BodyGene) -> [PetAction: [[[UInt8]]]] {
        switch body {
        case .cat: return CatSpriteData.child
        case .dog: return DogSpriteData.child
        case .rabbit: return RabbitSpriteData.child
        case .bird: return BirdSpriteData.child
        case .frog: return FrogSpriteData.child
        case .bear: return BearSpriteData.child
        case .dragon: return DragonSpriteData.child
        case .octopus: return OctopusSpriteData.child
        case .ghost: return GhostSpriteData.child
        case .slime: return SlimeSpriteData.child
        }
    }
}
