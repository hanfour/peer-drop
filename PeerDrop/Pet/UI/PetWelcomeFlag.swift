import Foundation

/// UserDefaults gate for the v4.0.1 pet-welcome reveal screen.
///
/// Triggers on first PetTab open for both:
/// - First-launch v4.0.1 users (brand new install)
/// - v3.x → v4.0.1 migrators whose .egg pet auto-promoted to .baby
///   (silent decoder maps legacy rawValue 1 → .baby, so they otherwise
///   see no welcome UX after upgrade)
final class PetWelcomeFlag {
    private let key: String
    private let defaults: UserDefaults

    init(key: String = "hasSeenPetWelcome_v4", defaults: UserDefaults = .standard) {
        self.key = key
        self.defaults = defaults
    }

    var shouldShow: Bool {
        !defaults.bool(forKey: key)
    }

    func markSeen() {
        defaults.set(true, forKey: key)
    }
}
