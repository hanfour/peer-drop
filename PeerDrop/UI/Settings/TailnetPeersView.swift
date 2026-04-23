import SwiftUI

struct TailnetPeersView: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @State private var showAddSheet = false

    var body: some View {
        List {
            Section(String(localized: "Tailnet Peers")) {
                if connectionManager.tailnetStore.entries.isEmpty {
                    Text(String(localized: "No tailnet peers added yet."))
                        .foregroundStyle(.secondary)
                }
                ForEach(connectionManager.tailnetStore.entries) { entry in
                    HStack {
                        Image(systemName: "network.badge.shield.half.filled")
                            .foregroundStyle(connectionManager.tailnetStore.isReachable(entry.id) ? .green : .orange)
                        VStack(alignment: .leading) {
                            Text(entry.displayName)
                            Text(entry.ip).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { indexSet in
                    for i in indexSet { connectionManager.tailnetStore.remove(id: connectionManager.tailnetStore.entries[i].id) }
                }
            }
        }
        .navigationTitle(String(localized: "Tailnet Devices"))
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { showAddSheet = true } label: { Image(systemName: "plus") } } }
        .sheet(isPresented: $showAddSheet) { AddTailnetPeerSheet().environmentObject(connectionManager) }
    }
}

struct AddTailnetPeerSheet: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var ip = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField(String(localized: "Display Name"), text: $name)
                TextField(String(localized: "Tailnet IP (100.x.x.x)"), text: $ip)
                    .keyboardType(.decimalPad)
                    .textInputAutocapitalization(.never)
                Section(footer: Text(String(localized: "Port defaults to 9876."))) { EmptyView() }
            }
            .navigationTitle(String(localized: "Add Tailnet Device"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Add")) {
                        connectionManager.tailnetStore.add(displayName: name, ip: ip)
                        dismiss()
                    }
                    .disabled(name.isEmpty || ip.isEmpty)
                }
            }
        }
    }
}
