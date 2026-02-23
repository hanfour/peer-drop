import SwiftUI

struct GroupRow: View {
    let group: DeviceGroup
    @EnvironmentObject var connectionManager: ConnectionManager

    private var memberCount: Int {
        group.deviceIDs.count
    }

    private var connectionStatus: (connected: Int, total: Int, online: Int) {
        connectionManager.groupConnectionStatus(group)
    }

    private var statusText: String {
        let status = connectionStatus
        if status.connected > 0 {
            return "\(status.connected)/\(status.total) connected"
        } else if status.online > 0 {
            return "\(status.online)/\(status.total) online"
        } else {
            return "\(status.total) members"
        }
    }

    private var statusColor: Color {
        let status = connectionStatus
        if status.connected > 0 {
            return .green
        } else if status.online > 0 {
            return .blue
        } else {
            return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            // Group icon
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.15))
                    .frame(width: 44, height: 44)

                Image(systemName: "person.3.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.blue)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(group.name)
                    .font(.body)
                    .foregroundStyle(.primary)

                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.name), \(statusText)")
    }
}
