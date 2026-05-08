import Foundation

extension PetAction {
    /// Maps PetAction onto the v5 normalized sprite zip's animation key.
    /// `.walking` maps to `"walk"` because PetAction.walking predates v5
    /// (used at 36 sites) and the metadata key follows the shorter convention
    /// from the design doc; renaming the case would be churn for no benefit.
    /// Returns nil for actions v5.0 doesn't ship animations for — caller is
    /// expected to fall back to single-frame static rendering.
    var animationKey: String? {
        switch self {
        case .walking: return "walk"
        case .idle:    return "idle"
        default:       return nil
        }
    }
}
