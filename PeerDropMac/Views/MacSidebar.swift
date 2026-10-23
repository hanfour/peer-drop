import SwiftUI

extension Notification.Name {
    /// Posted by PeerDropCommands when the user invokes ⌘⌥{1-4}.
    /// MacContentView observes and flips its sidebar selection.
    static let macSidebarJump = Notification.Name("com.hanfour.peerdrop.mac.sidebarJump")
}

/// Raw values mirror `AppTab.sidebarKey` (shared with iOS) so the two shells stay in lockstep.
enum MacSidebarSection: String, Hashable, CaseIterable, Identifiable {
    case home
    case notes
    case nearby
    case diaries

    var id: Self { self }

    var localizedName: String {
        switch self {
        case .home:    return NSLocalizedString("Home", comment: "")
        case .notes:   return NSLocalizedString("Notes", comment: "")
        case .nearby:  return NSLocalizedString("Nearby", comment: "")
        case .diaries: return NSLocalizedString("Diaries", comment: "")
        }
    }

    var icon: String {
        switch self {
        case .home:    return "house"
        case .notes:   return "envelope.fill"
        case .nearby:  return "wifi"
        case .diaries: return "book.closed"
        }
    }

    /// The iOS-shell tab this section corresponds to (used for `NearbyTab`'s `Binding<AppTab>`).
    var appTab: AppTab { AppTab(sidebarKey: rawValue) ?? .home }

    init(appTab: AppTab) { self = MacSidebarSection(rawValue: appTab.sidebarKey) ?? .home }
}

struct MacSidebar: View {
    @Binding var selection: MacSidebarSection?

    var body: some View {
        List(MacSidebarSection.allCases, selection: $selection) { section in
            Label(section.localizedName, systemImage: section.icon)
                .tag(section)
                .accessibilityLabel(section.localizedName)
                .accessibilityHint(Text("Jump to \(section.localizedName) section"))
        }
        .listStyle(.sidebar)
        .navigationTitle("PeerDrop")
    }
}
