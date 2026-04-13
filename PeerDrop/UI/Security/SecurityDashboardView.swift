import SwiftUI

struct SecurityDashboardView: View {
    @ObservedObject var contactStore: TrustedContactStore

    var body: some View {
        List {
            Section {
                protectionMeter
            }

            Section {
                statusRow(
                    icon: "lock",
                    label: String(localized: "Keys stored on device"),
                    isGood: true
                )
                statusRow(
                    icon: "lock.shield",
                    label: String(localized: "\(verifiedCount) verified contacts"),
                    isGood: verifiedCount > 0
                )
                if unverifiedCount > 0 {
                    statusRow(
                        icon: "exclamationmark.triangle",
                        label: String(localized: "\(unverifiedCount) contacts not yet verified"),
                        isGood: false
                    )
                }
                statusRow(
                    icon: "lock",
                    label: String(localized: "All conversations encrypted"),
                    isGood: true
                )
            } header: {
                Text("Security Status")
            }

            if !contactStore.nonBlocked.isEmpty {
                Section {
                    ForEach(contactStore.nonBlocked) { contact in
                        HStack {
                            Text(contact.displayName)
                            Spacer()
                            TrustBadgeView(trustLevel: contact.trustLevel)
                        }
                    }
                } header: {
                    Text("Contacts")
                }
            }

            Section {
                HStack {
                    Text("Identity Fingerprint")
                        .font(.subheadline)
                    Spacer()
                    Text(IdentityKeyManager.shared.fingerprint)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Your Device")
            }
        }
        .navigationTitle(String(localized: "Security"))
    }

    private var verifiedCount: Int {
        contactStore.contacts.filter { $0.trustLevel == .verified && !$0.isBlocked }.count
    }

    private var unverifiedCount: Int {
        contactStore.contacts.filter { $0.trustLevel != .verified && !$0.isBlocked }.count
    }

    private var protectionScore: Double {
        let total = contactStore.nonBlocked.count
        guard total > 0 else { return 1.0 }
        let verified = Double(verifiedCount)
        return (verified / Double(total)) * 0.7 + 0.3
    }

    private var protectionMeter: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.title)
                    .foregroundStyle(protectionColor)
                VStack(alignment: .leading) {
                    Text("Protection Level")
                        .font(.headline)
                    Text(protectionLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            ProgressView(value: protectionScore)
                .tint(protectionColor)
        }
        .padding(.vertical, 4)
    }

    private var protectionColor: Color {
        if protectionScore >= 0.8 { return .green }
        if protectionScore >= 0.5 { return .orange }
        return .red
    }

    private var protectionLabel: String {
        if protectionScore >= 0.8 { return String(localized: "Excellent") }
        if protectionScore >= 0.5 { return String(localized: "Good — verify remaining contacts") }
        return String(localized: "Needs attention")
    }

    private func statusRow(icon: String, label: String, isGood: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isGood ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundStyle(isGood ? .green : .orange)
            Text(label)
                .font(.subheadline)
        }
    }
}
