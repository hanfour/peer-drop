import Foundation

struct EvolutionRequirement {
    let targetLevel: PetLevel
    let requiredExperience: Int
    let socialBonus: Double
    let minimumAge: TimeInterval

    /// Returns the evolution requirement for evolving from the given level to the next.
    /// Returns nil if no evolution is defined for that level yet.
    static func `for`(_ level: PetLevel) -> EvolutionRequirement? {
        switch level {
        case .egg:
            return EvolutionRequirement(
                targetLevel: .baby,
                requiredExperience: 100,
                socialBonus: 1.5,
                minimumAge: 86400 // 24 hours
            )
        case .baby:
            return EvolutionRequirement(
                targetLevel: .child,
                requiredExperience: 500,
                socialBonus: 1.5,
                minimumAge: 259200 // 3 days
            )
        case .child:
            // Not yet implemented
            return nil
        }
    }
}
