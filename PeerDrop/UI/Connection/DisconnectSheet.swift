import SwiftUI

struct DisconnectSheet: View {
    @Environment(\.dismiss) private var dismiss
    let peerName: String
    let onDisconnect: () -> Void

    var body: some View {
        PeerActionSheet(
            peerName: peerName,
            subtitle: "Disconnect from this peer?",
            primaryLabel: "Disconnect",
            primaryColor: .red,
            secondaryLabel: "Cancel",
            onPrimary: { dismiss(); onDisconnect() },
            onSecondary: { dismiss() }
        )
    }
}
