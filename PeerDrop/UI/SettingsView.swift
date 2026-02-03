import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var displayName: String
    @AppStorage("messageStorageMode") private var storageMode = "local"

    init() {
        _displayName = State(
            initialValue: UserDefaults.standard.string(forKey: "peerDropDisplayName") ?? UIDevice.current.name
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Display Name", text: $displayName)
                        .autocorrectionDisabled()
                } header: {
                    Text("Identity")
                } footer: {
                    Text("This name is visible to nearby devices.")
                }

                Section("Profile") {
                    NavigationLink("Edit Profile") {
                        UserProfileView()
                    }
                }

                Section("Message Storage") {
                    Picker("Storage Mode", selection: $storageMode) {
                        Text("Local Only").tag("local")
                        Text("Sync to iCloud").tag("icloud")
                    }
                    .pickerStyle(.segmented)

                    Text("Messages are stored on this device only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    LabeledContent("Version", value: appVersion)
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        save()
                        dismiss()
                    }
                }
            }
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private func save() {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: "peerDropDisplayName")
        } else {
            UserDefaults.standard.set(trimmed, forKey: "peerDropDisplayName")
        }
    }
}
