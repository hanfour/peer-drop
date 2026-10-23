import SwiftUI
import PeerDropCore
import PeerDropNotes
import PeerDropDiary

struct MacContentView: View {
    @EnvironmentObject private var connectionManager: ConnectionManager
    @State private var selection: MacSidebarSection? = .home
    @State private var openNoteID: String?
    /// `DeviceRecord.id` of a bound friend whose chat a note deep link should open.
    @State private var threadRequest: ThreadRequest?
    /// Bumped by the `.openNote` deep link so Notes pushes its inbox (see `ConversationsTab.inboxRequest`).
    @State private var inboxRequest = 0
    @State private var diariesPath: [String] = []
    @State private var openDiaryID: String?
    @State private var openDiarySeq: Int?
    @AppStorage("sidebar.width") private var sidebarWidth: Double = 220
    @State private var isDropTargeted = false

    var body: some View {
        NavigationSplitView {
            MacSidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 180, ideal: sidebarWidth, max: 360)
        } detail: {
            MacDetailRouter(selection: $selection, inboxRequest: $inboxRequest, threadRequest: $threadRequest, openNoteID: $openNoteID,
                             diariesPath: $diariesPath, openDiaryID: $openDiaryID, openDiarySeq: $openDiarySeq)
                .navigationSplitViewColumnWidth(min: 480, ideal: 600)
        }
        .navigationSplitViewStyle(.balanced)
        .dropDestination(for: URL.self) { urls, _ in
            MacDropHandler.handle(urls: urls)
        } isTargeted: { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isDropTargeted = hovering
            }
        }
        .overlay(DropOverlay(isVisible: isDropTargeted), alignment: .center)
        // Security consent + first-contact verification sheets. Without
        // this, inbound connection requests have no accept UI on macOS and
        // the initiating peer always times out (see MacSecuritySheets.swift).
        .modifier(MacSecuritySheetsModifier())
        .onReceive(NotificationCenter.default.publisher(for: .macSidebarJump)) { note in
            if let section = note.object as? MacSidebarSection {
                selection = section
            }
        }
        // A relay invite link/push lands on Nearby, which hosts the RelayConnectView sheet.
        .onReceive(connectionManager.$shouldShowRelayConnect) { show in
            if show { selection = .nearby }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openNote)) { note in
            guard let id = note.userInfo?["id"] as? String else { return }
            selection = MacSidebarSection(appTab: AppTab.tab(forDeepLink: .openNote) ?? .notes)
            switch BoundFriends.destination(forNoteID: id, cm: connectionManager) {
            case .thread(let recordID):
                threadRequest = ThreadRequest(recordID: recordID, noteID: id)
            case .inbox:
                openNoteID = id
                inboxRequest += 1
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openDiary)) { note in
            guard let id = note.userInfo?["diaryId"] as? String else { return }
            selection = MacSidebarSection(appTab: AppTab.tab(forDeepLink: .openDiary) ?? .diaries)
            openDiaryID = id
            openDiarySeq = note.userInfo?["seq"] as? Int
        }
        // A pushed diary path must not survive switching away from and back
        // to its own section — otherwise the user lands back on a stale
        // diary instead of the list. (Notes/Home/Nearby own their stacks'
        // state inside their views and are rebuilt on section switch.)
        .onChange(of: selection) { newValue in
            if newValue != .diaries { diariesPath = [] }
        }
    }
}
