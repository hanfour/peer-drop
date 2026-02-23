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
                        .accessibilityLabel("IP Address or Hostname")
                        .accessibilityHint("Enter the peer's IP address or hostname")

                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                        .accessibilityLabel("Port")
                        .accessibilityHint("Enter port number, defaults to 9000")
                }

                Section("Display Name (Optional)") {
                    TextField("Name", text: $name)
                        .accessibilityLabel("Display Name")
                        .accessibilityHint("Optional name for this peer")
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
                    .accessibilityHint(host.isEmpty ? "Enter a host address first" : "Double tap to connect")
                }
            }
        }
    }
}
