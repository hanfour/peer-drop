import SwiftUI

/// Displays detailed read receipt status for a group message.
struct GroupReadReceiptView: View {
    let message: ChatMessage
    let members: [PeerIdentity]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // Summary section
                Section {
                    HStack {
                        Label("Delivered", systemImage: "checkmark")
                        Spacer()
                        Text("\(deliveredCount)/\(members.count)")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Delivered to \(deliveredCount) of \(members.count)")

                    HStack {
                        Label("Read", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.cyan)
                        Spacer()
                        Text("\(readCount)/\(members.count)")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Read by \(readCount) of \(members.count)")
                }

                // Individual member status
                Section("Members") {
                    ForEach(members, id: \.id) { member in
                        HStack {
                            PeerAvatar(name: member.displayName)
                                .scaleEffect(0.8)

                            Text(member.displayName)

                            Spacer()

                            statusIcon(for: member.id)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(member.displayName), \(statusLabel(for: member.id))")
                    }
                }
            }
            .navigationTitle("Message Status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var deliveredCount: Int {
        message.groupReadStatus?.deliveredTo.count ?? 0
    }

    private var readCount: Int {
        message.groupReadStatus?.readBy.count ?? 0
    }

    private func statusLabel(for memberID: String) -> String {
        guard let status = message.groupReadStatus else { return "Pending" }
        if status.readBy.contains(memberID) { return "Read" }
        if status.deliveredTo.contains(memberID) { return "Delivered" }
        return "Sent"
    }

    @ViewBuilder
    private func statusIcon(for memberID: String) -> some View {
        if let status = message.groupReadStatus {
            if status.readBy.contains(memberID) {
                // Read
                HStack(spacing: -4) {
                    Image(systemName: "checkmark")
                    Image(systemName: "checkmark")
                }
                .font(.caption)
                .foregroundStyle(.cyan)
            } else if status.deliveredTo.contains(memberID) {
                // Delivered
                HStack(spacing: -4) {
                    Image(systemName: "checkmark")
                    Image(systemName: "checkmark")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                // Sent (pending delivery)
                Image(systemName: "checkmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            // No status yet
            Image(systemName: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
