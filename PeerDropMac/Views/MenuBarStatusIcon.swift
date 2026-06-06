import SwiftUI
import PeerDropCore

struct MenuBarStatusIcon: View {
    let state: ConnectionState

    var body: some View {
        // Task 8 replaces with state-driven SF Symbol switch.
        Image(systemName: "circle.dotted")
    }
}
