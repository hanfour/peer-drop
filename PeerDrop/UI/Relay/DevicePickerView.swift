import SwiftUI

struct DevicePickerView: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @Environment(\.dismiss) private var dismiss

    @State private var availableDevices: [DeviceRecord] = []
    @State private var busyDeviceId: String?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            List {
                Section(String(localized: "Invite a known device")) {
                    if availableDevices.isEmpty {
                        Text(String(localized: "No known devices yet. Share a room code manually for the first connection."))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(availableDevices) { device in
                        Button {
                            Task { await invite(device) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(device.displayName).font(.body)
                                    if let peerId = device.peerDeviceId {
                                        Text(peerId.prefix(8) + "...")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    } else {
                                        Text(String(localized: "Device ID not yet known"))
                                            .font(.caption2).foregroundStyle(.orange)
                                    }
                                }
                                Spacer()
                                if busyDeviceId == device.id { ProgressView() }
                            }
                        }
                        .disabled(device.peerDeviceId == nil || busyDeviceId != nil)
                    }
                }
                if let errorText {
                    Section { Text(errorText).foregroundStyle(.red) }
                }
            }
            .navigationTitle(String(localized: "Invite"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
            }
            .onAppear { refresh() }
        }
    }

    private func refresh() {
        availableDevices = connectionManager.deviceStore.allRecords()
            .filter { $0.peerDeviceId != nil }
            .sorted { $0.lastConnected > $1.lastConnected }
    }

    private func invite(_ device: DeviceRecord) async {
        busyDeviceId = device.id
        errorText = nil
        defer { busyDeviceId = nil }
        await connectionManager.inviteKnownDevice(device)
        if let err = connectionManager.inviteError {
            errorText = err
        } else {
            dismiss()
        }
    }
}
