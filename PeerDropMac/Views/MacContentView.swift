import SwiftUI
import PeerDropCore

struct MacContentView: View {
    @State private var selection: MacSidebarSection? = .nearby
    @AppStorage("sidebar.width") private var sidebarWidth: Double = 220

    var body: some View {
        NavigationSplitView {
            MacSidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 180, ideal: sidebarWidth, max: 360)
        } detail: {
            MacDetailRouter(section: selection)
                .navigationSplitViewColumnWidth(min: 480, ideal: 600)
        }
        .navigationSplitViewStyle(.balanced)
    }
}
