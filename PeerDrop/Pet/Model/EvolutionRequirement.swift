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
        case .baby:
            return EvolutionRequirement(
                targetLevel: .adult,
                requiredExperience: 500,
                socialBonus: 1.5,
                minimumAge: 259200 // 3 days
            )
        case .adult:
            // Adult→elder is age-driven (handled in PetEngine, not via experience).
            return nil
        case .elder:
            // Final stage.
            return nil
        }
    }
}
