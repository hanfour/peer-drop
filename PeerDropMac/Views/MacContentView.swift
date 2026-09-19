import SwiftUI
import PeerDropCore
import PeerDropNotes

struct MacContentView: View {
    @State private var selection: MacSidebarSection? = .notes
    @State private var notesPath: [NoteRecord] = []
    @State private var openNoteID: String?
    @AppStorage("sidebar.width") private var sidebarWidth: Double = 220
    @State private var isDropTargeted = false

    var body: some View {
        NavigationSplitView {
            MacSidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 180, ideal: sidebarWidth, max: 360)
        } detail: {
            MacDetailRouter(section: selection, notesPath: $notesPath, openNoteID: $openNoteID)
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
        .onReceive(NotificationCenter.default.publisher(for: .openNote)) { note in
            guard let id = note.userInfo?["id"] as? String else { return }
            selection = .notes
            openNoteID = id
        }
    }
}
