import SwiftUI
import PeerDropCore

/// Routes the selected sidebar section to its detail content.
///
/// M4 Task 1b wired the four real section views (NearbyTab,
/// LibraryTab, RelayConnectView, PetSectionView) after their iOS
/// dependencies were cross-platformed via `PlatformImage` +
/// `Image(platformImage:)` + cross-platform pasteboard / file
/// pickers / QR rendering.
struct MacDetailRouter: View {
    let section: MacSidebarSection?
    @EnvironmentObject var connectionManager: ConnectionManager
    // `NearbyTab` uses this binding on iOS to flip the parent TabView's
    // selected index after certain actions. macOS has no tab parent —
    // the sidebar (`MacSidebar`) owns navigation — so we feed a
    // throwaway state slot that nothing observes.
    @State private var nearbyTabIndex: Int = 0

    var body: some View {
        NavigationStack {
            switch section {
            case .nearby:
                NearbyTab(selectedTab: $nearbyTabIndex)
                    .environmentObject(connectionManager)
            case .trusted:
                LibraryTab()
                    .environmentObject(connectionManager)
            case .relay:
                RelayConnectView()
                    .environmentObject(connectionManager)
            case .pet:
                PetSectionView()
            case .none:
                ContentUnavailableView(
                    "Choose a section",
                    systemImage: "sidebar.left",
                    description: Text("Pick Nearby, Trusted, Relay, or Pet from the sidebar.")
                )
            }
        }
    }
}
