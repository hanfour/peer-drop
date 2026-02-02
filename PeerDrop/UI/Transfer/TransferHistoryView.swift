import SwiftUI

struct TransferHistoryView: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if connectionManager.transferHistory.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No transfers yet")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(connectionManager.transferHistory) { record in
                    HStack(spacing: 12) {
                        Image(systemName: record.direction == .sent ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                            .foregroundStyle(record.direction == .sent ? .blue : .green)
                            .font(.title3)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.fileName)
                                .font(.body)
                                .lineLimit(1)

                            HStack(spacing: 6) {
                                Text(record.formattedSize)
                                Text("·")
                                Text(record.timestamp, style: .time)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Image(systemName: record.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(record.success ? .green : .red)
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Transfer History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    dismiss()
                }
            }
        }
    }
}
