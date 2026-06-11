import SwiftUI
import PeerDropCore
import PeerDropSecurity  // for PeerIdentity

struct MacSettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gear") }

            ProfileSettingsTab()
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }

            RelaySettingsTab()
                .tabItem { Label("Relay", systemImage: "network") }

            SupportSettingsTab()
                .tabItem { Label("Support", systemImage: "heart.fill") }
        }
        .frame(width: 520, height: 420)
    }
}

// MARK: - Support (Tip Jar)

/// Hosts the cross-platform `TipJarSection` so Mac users can find the
/// IAPs attached to the Mac binary via M4 Task 10 (Playwright). Without
/// this surface, the IAPs would be listed in ASC but unreachable from
/// the app — Apple Guideline 2.1 reject risk.
private struct SupportSettingsTab: View {
    var body: some View {
        Form {
            TipJarSection()
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @AppStorage("peerDropDisplayName") private var displayName: String = ""

    var body: some View {
        Form {
            Section {
                TextField("Display Name", text: $displayName)
                    .textFieldStyle(.roundedBorder)
                Text("This name appears to other devices when they discover yours.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Device")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Profile

private struct ProfileSettingsTab: View {
    @EnvironmentObject var connectionManager: ConnectionManager

    var body: some View {
        Form {
            Section {
                LabeledContent("Identity") {
                    Text(connectionManager.localIdentity.displayName)
                        .font(.body.monospaced())
                }
                LabeledContent("ID") {
                    Text(connectionManager.localIdentity.id)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let fingerprint = connectionManager.localIdentity.identityFingerprint {
                    LabeledContent("Fingerprint") {
                        Text(fingerprint)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text("Identity")
            } footer: {
                Text("Compare the fingerprint when pairing with another device to confirm a secure channel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Relay

private struct RelaySettingsTab: View {
    @AppStorage("peerDropRelayEnabled") private var relayEnabled: Bool = true
    @AppStorage("peerDropWorkerURL") private var workerURL: String = ""

    var body: some View {
        Form {
            Section {
                Toggle("Enable Relay", isOn: $relayEnabled)
                Text("Use the Cloudflare Worker relay when devices can't reach each other on the same network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Relay")
            }

            Section {
                TextField("Worker URL", text: $workerURL, prompt: Text("https://peerdrop-signal.hanfourhuang.workers.dev"))
                    .textFieldStyle(.roundedBorder)
                Text("Leave blank to use the bundled default. Restart the app after changing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Advanced")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
