import SwiftUI

struct DeviceRecordRow: View {
    let record: DeviceRecord
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                PeerAvatar(name: record.displayName)

                VStack(alignment: .leading, spacing: 2) {
                    Text(record.displayName)
                        .font(.body)
                        .foregroundStyle(.primary)

                    HStack(spacing: 4) {
                        Text(record.relativeLastConnected)
                        Text("\u{00B7}")
                        Text("\(record.connectionCount) connections")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: record.sourceType == "manual" ? "network" : "wifi")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
        }
        .accessibilityLabel("\(record.displayName), \(record.relativeLastConnected), \(record.connectionCount) connections")
    }
}
