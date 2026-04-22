import SwiftUI
import UIKit

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
        guard let peerDeviceId = device.peerDeviceId else { return }
        busyDeviceId = device.id
        errorText = nil
        defer { busyDeviceId = nil }
        do {
            let signaling = WorkerSignaling()
            let room = try await signaling.createRoom()
            guard let roomToken = room.roomToken else {
                errorText = String(localized: "Server did not return room token")
                return
            }
            let senderName = UIDevice.current.name
            try await signaling.sendInvite(
                toDeviceId: peerDeviceId,
                roomCode: room.roomCode,
                roomToken: roomToken,
                senderName: senderName,
                senderId: DeviceIdentity.deviceId
            )
            await MainActor.run {
                connectionManager.startWorkerRelayAsCreator(
                    roomCode: room.roomCode,
                    roomToken: roomToken,
                    signaling: signaling
                )
                dismiss()
            }
        } catch {
            errorText = error.localizedDescription
        }
    }
}
