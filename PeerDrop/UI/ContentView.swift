import SwiftUI

struct ContentView: View {
    @EnvironmentObject var connectionManager: ConnectionManager

    var body: some View {
        NavigationStack {
            DiscoveryView()
                .navigationTitle("PeerDrop")
                .sheet(item: $connectionManager.pendingIncomingRequest) { request in
                    ConsentSheet(request: request)
                        .environmentObject(connectionManager)
                }
                .sheet(isPresented: $connectionManager.showTransferProgress) {
                    TransferProgressView()
                        .environmentObject(connectionManager)
                }
                .sheet(isPresented: $connectionManager.showVoiceCall) {
                    VoiceCallView()
                        .environmentObject(connectionManager)
                }
        }
    }
}
