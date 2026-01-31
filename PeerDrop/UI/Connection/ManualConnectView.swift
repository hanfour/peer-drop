import SwiftUI

struct ManualConnectView: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @Environment(\.dismiss) private var dismiss

    @State private var host = ""
    @State private var port = "9000"
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Peer Address") {
                    TextField("IP Address or Hostname", text: $host)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                }

                Section("Display Name (Optional)") {
                    TextField("Name", text: $name)
                }
            }
            .navigationTitle("Manual Connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        guard let portNum = UInt16(port), !host.isEmpty else { return }
                        connectionManager.addManualPeer(
                            host: host,
                            port: portNum,
                            name: name.isEmpty ? nil : name
                        )
                        dismiss()
                    }
                    .disabled(host.isEmpty || UInt16(port) == nil)
                }
            }
        }
    }
}
