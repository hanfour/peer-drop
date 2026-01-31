import SwiftUI

struct TransferProgressView: View {
    @EnvironmentObject var connectionManager: ConnectionManager

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "doc.fill")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text(transferLabel)
                .font(.headline)

            if let transfer = connectionManager.fileTransfer {
                ProgressView(value: transfer.progress)
                    .progressViewStyle(.linear)
                    .padding(.horizontal, 40)

                Text("\(Int(transfer.progress * 100))%")
                    .font(.title2.monospacedDigit())
                    .foregroundStyle(.secondary)

                if let error = transfer.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Spacer()

            Button("Cancel") {
                connectionManager.disconnect()
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .padding(.bottom, 32)
        }
        .presentationDetents([.medium])
    }

    private var transferLabel: String {
        if case .transferring = connectionManager.state {
            return "Transferring..."
        }
        return "Transfer"
    }
}
