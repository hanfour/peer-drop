import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var displayName: String

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
