import Foundation

/// The four top-level destinations of the iOS shell (order = tab bar order).
/// Raw values are stable; never reorder without a migration of anything that persists them.
enum AppTab: Int, CaseIterable {
    case home, notes, nearby, diaries

    /// Which tab a deep-link notification should land on.
    static func tab(forDeepLink name: Notification.Name) -> AppTab? {
        switch name {
        case .openNote: return .notes
        case .openDiary: return .diaries
        default: return nil
        }
    }
}
