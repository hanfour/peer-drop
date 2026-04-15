import Foundation

enum PetBehaviorProviderFactory {
    static func create(for body: BodyGene) -> PetBehaviorProvider {
        switch body {
        case .cat:      return CatBehavior()
        case .dog:      return DogBehavior()
        case .rabbit:   return RabbitBehavior()
        case .bird:     return BirdBehavior()
        case .frog:     return FrogBehavior()
        case .bear:     return BearBehavior()
        case .dragon:   return DragonBehavior()
        case .octopus:  return OctopusBehavior()
        case .ghost:    return GhostBehavior()
        case .slime:    return SlimeBehavior()
        }
    }
}
