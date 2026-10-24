import Foundation
import PeerDropCore

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

    /// Which tab to show after the global connection state changes. Only a genuinely NEW
    /// connection (coming from a not-yet-connected state) made while the user is on the
    /// Nearby tab moves to Home; transitions among connected/transferring/voiceCall and
    /// anything that happens while the user is in Notes/Diaries never switch tabs.
    static func tabAfterConnectionChange(from old: ConnectionState, to new: ConnectionState, current: AppTab) -> AppTab {
        guard current == .nearby else { return current }
        func isLive(_ s: ConnectionState) -> Bool {
            switch s {
            case .connected, .transferring, .voiceCall: return true
            default: return false
            }
        }
        return (!isLive(old) && isLive(new)) ? .home : current
    }

    /// Stable string key shared with the Mac sidebar (`MacSidebarSection.rawValue`).
    var sidebarKey: String {
        switch self {
        case .home: return "home"
        case .notes: return "notes"
        case .nearby: return "nearby"
        case .diaries: return "diaries"
        }
    }

    init?(sidebarKey: String) {
        guard let tab = AppTab.allCases.first(where: { $0.sidebarKey == sidebarKey }) else { return nil }
        self = tab
    }
}
