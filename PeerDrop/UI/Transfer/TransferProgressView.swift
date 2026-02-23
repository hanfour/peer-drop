import SwiftUI

struct TransferProgressView: View {
    @EnvironmentObject var connectionManager: ConnectionManager

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "doc.fill")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            if let name = connectionManager.fileTransfer?.currentFileName {
                Text(name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let transfer = connectionManager.fileTransfer, transfer.totalFileCount > 1 {
                Text("File \(transfer.currentFileIndex) of \(transfer.totalFileCount)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text(transferLabel)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let transfer = connectionManager.fileTransfer {
                ProgressView(value: transfer.progress)
                    .progressViewStyle(.linear)
                    .padding(.horizontal, 40)
                    .accessibilityLabel("Transfer progress")
                    .accessibilityValue("\(Int(transfer.progress * 100)) percent")

                Text("\(Int(transfer.progress * 100))%")
                    .font(.title2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                if let error = transfer.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Transfer error: \(error)")
                }
            }

            Spacer()

            Button("Cancel Transfer") {
                connectionManager.fileTransfer?.cancelTransfer()
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .padding(.bottom, 32)
            .accessibilityHint("Cancels the current file transfer")
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
