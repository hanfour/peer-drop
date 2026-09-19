import SwiftUI

extension Notification.Name {
    /// Posted by PeerDropCommands when the user invokes ⌘⌥{1-4}.
    /// MacContentView observes and flips its sidebar selection.
    static let macSidebarJump = Notification.Name("com.hanfour.peerdrop.mac.sidebarJump")
}

enum MacSidebarSection: String, Hashable, CaseIterable, Identifiable {
    case notes
    case nearby
    case trusted
    case relay

    var id: Self { self }

    var localizedName: String {
        switch self {
        case .notes:   return NSLocalizedString("Notes", comment: "")
        case .nearby:  return NSLocalizedString("Nearby", comment: "")
        case .trusted: return NSLocalizedString("Library", comment: "")
        case .relay:   return NSLocalizedString("Relay", comment: "")
        }
    }

    var icon: String {
        switch self {
        case .notes:   return "envelope.fill"
        case .nearby:  return "wifi"
        case .trusted: return "checkmark.shield"
        case .relay:   return "network"
        }
    }
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
