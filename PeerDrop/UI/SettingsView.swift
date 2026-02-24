import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var displayName: String
    @AppStorage("messageStorageMode") private var storageMode = "local"
    @AppStorage("peerDropFileTransferEnabled") private var fileTransferEnabled = true
    @AppStorage("peerDropVoiceCallEnabled") private var voiceCallEnabled = true
    @AppStorage("peerDropChatEnabled") private var chatEnabled = true
    @AppStorage("peerDropNotificationsEnabled") private var notificationsEnabled = false
    @State private var showNotificationDeniedAlert = false
    @EnvironmentObject var connectionManager: ConnectionManager
    @State private var showShareSheet = false
    @State private var exportURL: URL?
    @State private var showDocumentPicker = false
    @State private var showImportChoice = false
    @State private var importURL: URL?
    @State private var archiveError: String?
    @State private var showArchiveError = false

    init() {
        _displayName = State(initialValue: UserDefaults.standard.string(forKey: "peerDropDisplayName") ?? UIDevice.current.name)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("Display Name", text: $displayName).autocorrectionDisabled() } header: { Text("Identity") } footer: { Text("This name is visible to nearby devices.") }
                Section("Profile") { NavigationLink("Edit Profile") { UserProfileView() } }
                Section {
                    Toggle("File Transfer", isOn: $fileTransferEnabled)
                        .accessibilityHint("Allows sending and receiving files")
                    Toggle("Voice Calls", isOn: $voiceCallEnabled)
                        .accessibilityHint("Allows making and receiving voice calls")
                    Toggle("Chat", isOn: $chatEnabled)
                        .accessibilityHint("Allows sending and receiving messages")
                } header: { Text("Connectivity") } footer: { Text("Disabled features will reject incoming requests automatically.") }
                Section { Toggle("Enable Notifications", isOn: $notificationsEnabled) } header: { Text("Notifications") } footer: { Text("Receive alerts for incoming connections and messages.") }
                Section("Message Storage") { Picker("Storage Mode", selection: $storageMode) { Text("Local Only").tag("local"); Text("Sync to iCloud").tag("icloud") }.pickerStyle(.segmented); Text("Messages are stored on this device only.").font(.caption).foregroundStyle(.secondary) }
                Section {
                    Button { exportArchive() } label: { Label("Export Archive", systemImage: "square.and.arrow.up") }
                        .accessibilityHint("Exports device records, transfer history, and chat data")
                    Button { showDocumentPicker = true } label: { Label("Import Archive", systemImage: "square.and.arrow.down") }
                        .accessibilityHint("Imports data from a previously exported archive")
                } header: { Text("Archive") } footer: { Text("Export or import your device records, transfer history, and chat data.") }
                Section { LabeledContent("Version", value: appVersion) } header: { Text("About") }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { save(); dismiss() } } }
            .onChange(of: notificationsEnabled) { enabled in
                if enabled {
                    Task {
                        let granted = await NotificationManager.shared.requestPermission()
                        if !granted { await MainActor.run { notificationsEnabled = false; showNotificationDeniedAlert = true } }
                    }
                }
            }
            .alert("Notifications Denied", isPresented: $showNotificationDeniedAlert) { Button("OK", role: .cancel) {} } message: { Text("Please enable notifications in Settings to receive alerts.") }
            .alert("Archive Error", isPresented: $showArchiveError) { Button("OK", role: .cancel) {} } message: { Text(archiveError ?? "An unknown error occurred.") }
            .sheet(isPresented: $showShareSheet) { if let url = exportURL { ShareSheet(items: [url]) } }
            .sheet(isPresented: $showDocumentPicker) { ArchiveDocumentPickerView(contentTypes: [.zip]) { url in importURL = url; showImportChoice = true } }
            .confirmationDialog("Import Mode", isPresented: $showImportChoice, titleVisibility: .visible) { Button("Merge with existing data") { performImport(merge: true) }; Button("Replace all data", role: .destructive) { performImport(merge: false) }; Button("Cancel", role: .cancel) {} }
        }
    }

    private var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }

    private func save() {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { UserDefaults.standard.removeObject(forKey: "peerDropDisplayName") } else { UserDefaults.standard.set(trimmed, forKey: "peerDropDisplayName") }
    }

    private func exportArchive() {
        Task {
            do { let url = try await ArchiveManager.exportArchive(deviceStore: connectionManager.deviceStore, transferHistory: connectionManager.transferHistory, chatManager: connectionManager.chatManager); exportURL = url; showShareSheet = true }
            catch { archiveError = error.localizedDescription; showArchiveError = true }
        }
    }

    private func performImport(merge: Bool) {
        guard let url = importURL else { return }
        do { try ArchiveManager.importArchive(from: url, merge: merge, deviceStore: connectionManager.deviceStore, connectionManager: connectionManager) }
        catch { archiveError = error.localizedDescription; showArchiveError = true }
    }
}
