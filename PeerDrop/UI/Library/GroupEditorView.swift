import SwiftUI

struct GroupEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var groupStore: DeviceGroupStore
    @State private var name: String
    let group: DeviceGroup?

    init(groupStore: DeviceGroupStore, group: DeviceGroup? = nil) {
        self.groupStore = groupStore
        self.group = group
        _name = State(initialValue: group?.name ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Group Name") {
                    TextField("Name", text: $name)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Group Name")
                        .accessibilityHint("Enter a name for this group")
                }
            }
            .navigationTitle(group == nil ? "New Group" : "Edit Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveGroup()
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityHint(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Enter a group name first" : "Double tap to save")
                }
            }
        }
    }

    private func saveGroup() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if var existing = group {
            existing.name = trimmed
            groupStore.update(existing)
        } else {
            groupStore.add(name: trimmed)
        }
    }
}
