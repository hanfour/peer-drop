import Foundation

public enum PetBehaviorProviderFactory {
    public static func create(for body: BodyGene) -> PetBehaviorProvider {
        switch body {
        case .cat:      return CatBehavior()
        case .dog:      return DogBehavior()
        case .rabbit:   return RabbitBehavior()
        case .bird:     return BirdBehavior()
        case .frog:     return FrogBehavior()
        case .bear:     return BearBehavior()
        case .dragon:   return DragonBehavior()
        case .octopus:  return OctopusBehavior()
        case .slime:    return SlimeBehavior()
        // Expansion families (2026-06-14) share a generic grounded behaviour
        // until bespoke ones are written. Their sprites are already correct.
        default:        return GenericBehavior()
        }
    }
}
