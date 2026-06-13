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
    /// When `requiresRecentActivity` is true, the pet must have interacted
    /// within this window for the transition to fire. nil when activity isn't
    /// gated. This makes `EvolutionRequirement` the single source of truth for
    /// every evolution threshold — `PetEngine.checkEvolution` reads these
    /// values rather than re-declaring its own constants (which used to drift
    /// from the UI's progress maths; see the resolved FIXME).
    public let recentActivityWindow: TimeInterval?

    public init(
        targetLevel: PetLevel,
        minimumAge: TimeInterval,
        requiresRecentActivity: Bool,
        recentActivityWindow: TimeInterval? = nil
    ) {
        self.targetLevel = targetLevel
        self.minimumAge = minimumAge
        self.requiresRecentActivity = requiresRecentActivity
        self.recentActivityWindow = recentActivityWindow
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
                requiresRecentActivity: true,
                recentActivityWindow: 30 * 86400
            )
        case .elder:
            return nil
        }
    }
}
