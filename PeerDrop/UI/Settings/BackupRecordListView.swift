import SwiftUI

struct BackupRecordListView: View {
    let records: [DeviceRecord]

    var body: some View {
        List {
            if records.isEmpty {
                Text("No backup records available.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(records) { record in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.displayName)
                            .font(.headline)
                        Text("Last connected: \(record.relativeLastConnected)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Connections: \(record.connectionCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Backup Records")
        .navigationBarTitleDisplayMode(.inline)
    }
}
