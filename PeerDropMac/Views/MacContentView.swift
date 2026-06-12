import SwiftUI
import PeerDropCore

struct MacContentView: View {
    @State private var selection: MacSidebarSection? = .nearby
    @AppStorage("sidebar.width") private var sidebarWidth: Double = 220
    @State private var isDropTargeted = false

    var body: some View {
        NavigationSplitView {
            MacSidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 180, ideal: sidebarWidth, max: 360)
        } detail: {
            MacDetailRouter(section: selection)
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
    }
}
