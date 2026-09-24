import SwiftUI
import PeerDropCore
import PeerDropNotes
import PeerDropDiary

/// Routes the selected sidebar section to its detail content.
///
/// M4 Task 1b wired the three real section views (NearbyTab,
/// LibraryTab, RelayConnectView) after their iOS
/// dependencies were cross-platformed via `PlatformImage` +
/// `Image(platformImage:)` + cross-platform pasteboard / file
/// pickers / QR rendering.
///
/// Task 6: each section now gets its OWN `NavigationStack` (previously
/// every section shared one `NavigationStack(path: $notesPath)`, which
/// only ever worked because nothing but Notes pushed a typed path value
/// onto it). Diaries needs a `[String]`-typed path distinct from Notes'
/// `[NoteRecord]`, so splitting per-section is the simplest correct fix —
/// it also mirrors iOS `ContentView`, where every tab already owns its own
/// `NavigationStack`.
struct MacDetailRouter: View {
    let section: MacSidebarSection?
    @Binding var notesPath: [NoteRecord]
    @Binding var openNoteID: String?
    @Binding var diariesPath: [String]
    @Binding var openDiaryID: String?
    @Binding var openDiarySeq: Int?
    @EnvironmentObject var connectionManager: ConnectionManager
    // `NearbyTab` uses this binding on iOS to flip the parent TabView's
    // selected index after certain actions. macOS has no tab parent —
    // the sidebar (`MacSidebar`) owns navigation — so we feed a
    // throwaway state slot that nothing observes.
    @State private var nearbyTabIndex: Int = 0

    var body: some View {
        switch section {
        case .notes:
            NavigationStack(path: $notesPath) {
                NotesInboxView(store: connectionManager.notesStore, accountManager: connectionManager.accountManager, openNoteID: $openNoteID, path: $notesPath)
                    .environmentObject(connectionManager)
            }
        case .diaries:
            NavigationStack(path: $diariesPath) {
                DiaryListView(store: connectionManager.diaryStore, accountManager: connectionManager.accountManager,
                               openDiaryID: $openDiaryID, openDiarySeq: $openDiarySeq, path: $diariesPath)
                    .environmentObject(connectionManager)
            }
        case .nearby:
            NavigationStack {
                NearbyTab(selectedTab: $nearbyTabIndex)
                    .environmentObject(connectionManager)
            }
        case .trusted:
            NavigationStack {
                LibraryTab()
                    .environmentObject(connectionManager)
            }
        case .relay:
            NavigationStack {
                RelayConnectView()
                    .environmentObject(connectionManager)
            }
        case .none:
            ContentUnavailableView(
                "Choose a section",
                systemImage: "sidebar.left",
                description: Text("Pick Notes, Diaries, Nearby, Library, or Relay from the sidebar.")
            )
        }
    }
}
