import Foundation

/// Per-level evolution gate. v5.0.x: aligned with the actual rule enforced
/// by `PetEngine.checkEvolution`, which is purely age-based:
///
///   - baby  → adult : age ≥ 8 days
///   - adult → elder : age ≥ 90 days AND interacted within the last 30 days
///
/// Prior versions of this struct carried `requiredExperience` and
/// `socialBonus` fields that the engine never consulted, which surfaced as
/// misleading XP progress bars and "EXP is ready" hints in the UI. Both
/// fields were removed.
public struct EvolutionRequirement {
    public let targetLevel: PetLevel
    public let minimumAge: TimeInterval
    /// True when the engine also gates on recent interaction. Today only the
    /// adult→elder transition does. UI uses this to render an appropriate
    /// "stay active" caveat alongside the age progress.
    public let requiresRecentActivity: Bool

    public init(targetLevel: PetLevel, minimumAge: TimeInterval, requiresRecentActivity: Bool) {
        self.targetLevel = targetLevel; self.minimumAge = minimumAge
        self.requiresRecentActivity = requiresRecentActivity
    }

    /// Returns the evolution requirement for evolving from the given level
    /// to the next. Returns nil for `elder` (final stage).
    public static func `for`(_ level: PetLevel) -> EvolutionRequirement? {
        switch level {
        case .baby:
            return EvolutionRequirement(
                targetLevel: .adult,
                minimumAge: 8 * 86400,
                requiresRecentActivity: false
            )
        case .adult:
            return EvolutionRequirement(
                targetLevel: .elder,
                minimumAge: 90 * 86400,
                requiresRecentActivity: true
            )
        case .elder:
            return nil
        }
    }
}
