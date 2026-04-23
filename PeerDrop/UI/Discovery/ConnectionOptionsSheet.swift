import SwiftUI

struct ConnectionOptionsSheet: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @Environment(\.dismiss) private var dismiss
    @State private var showManualConnect = false

    var body: some View {
        NavigationStack {
            List {
                Section(String(localized: "Cross-Network")) {
                    Button(String(localized: "Create Relay Room")) { connectionManager.shouldShowRelayConnect = true; dismiss() }
                    Button(String(localized: "Invite known device")) { connectionManager.shouldShowRelayConnect = true; dismiss() }
                }
                Section(String(localized: "Advanced")) {
                    Button(String(localized: "Connect by IP address")) { showManualConnect = true }
                    NavigationLink(String(localized: "Manage tailnet peers")) {
                        TailnetPeersView().environmentObject(connectionManager)
                    }
                }
            }
            .navigationTitle(String(localized: "Connection Options"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Close")) { dismiss() } } }
            .sheet(isPresented: $showManualConnect) {
                ManualConnectView().environmentObject(connectionManager)
            }
        }
    }
}
