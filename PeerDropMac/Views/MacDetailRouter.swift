import SwiftUI
import PeerDropCore
import PeerDropNotes
import PeerDropDiary

/// Routes the selected sidebar section to its detail content.
///
/// M4 Task 1b wired the three real section views (NearbyTab,
/// HomeTab, RelayConnectView) after their iOS
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
    @Binding var selection: MacSidebarSection?
    @Binding var inboxRequest: Int
    @Binding var threadRequest: ThreadRequest?
    @Binding var openNoteID: String?
    @Binding var diariesPath: [String]
    @Binding var openDiaryID: String?
    @Binding var openDiarySeq: Int?
    @EnvironmentObject var connectionManager: ConnectionManager

    /// `NearbyTab` flips the iOS TabView through this binding (e.g. to `.home` after connecting).
    /// On macOS the sidebar owns navigation, so the binding reads/writes the sidebar selection.
    private var tabBinding: Binding<AppTab> {
        Binding(
            get: { (selection ?? .nearby).appTab },
            set: { selection = MacSidebarSection(appTab: $0) }
        )
    }

    var body: some View {
        switch selection {
        case .home:
            NavigationStack {
                HomeTab(onAddFriend: { selection = .nearby })
                    .environmentObject(connectionManager)
            }
        case .notes:
            ConversationsTabContent(
                store: connectionManager.notesStore,
                accountManager: connectionManager.accountManager,
                openNoteID: $openNoteID,
                inboxRequest: $inboxRequest,
                threadRequest: $threadRequest,
                onGoHome: { selection = .home }
            )
            .environmentObject(connectionManager)
        case .diaries:
            NavigationStack(path: $diariesPath) {
                DiaryListView(store: connectionManager.diaryStore, accountManager: connectionManager.accountManager,
                               openDiaryID: $openDiaryID, openDiarySeq: $openDiarySeq, path: $diariesPath)
                    .environmentObject(connectionManager)
            }
        case .nearby:
            NavigationStack {
                NearbyTab(selectedTab: tabBinding)
                    .environmentObject(connectionManager)
            }
        case .none:
            ContentUnavailableView(
                "Choose a section",
                systemImage: "sidebar.left",
                description: Text("Pick Home, Notes, Nearby, or Diaries from the sidebar.")
            )
        }
    }
}
