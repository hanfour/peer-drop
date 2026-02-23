import SwiftUI

struct AssignGroupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var groupStore: DeviceGroupStore
    let deviceID: String

    var body: some View {
        NavigationStack {
            List {
                if groupStore.groups.isEmpty {
                    Text("No groups yet. Create one first.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(groupStore.groups) { group in
                        Button {
                            groupStore.addDevice(deviceID, toGroup: group.id)
                            dismiss()
                        } label: {
                            HStack {
                                Text(group.name)
                                Spacer()
                                if group.deviceIDs.contains(deviceID) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                        .accessibilityLabel(group.name)
                        .accessibilityValue(group.deviceIDs.contains(deviceID) ? "Already assigned" : "")
                        .accessibilityHint("Double tap to assign device to this group")
                    }
                }
            }
            .navigationTitle("Assign to Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
