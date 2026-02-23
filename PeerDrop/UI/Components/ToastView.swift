import SwiftUI

struct ToastView: View {
    let record: TransferRecord

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: record.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(record.success ? .green : .red)

            VStack(alignment: .leading, spacing: 2) {
                Text(record.fileName)
                    .font(.subheadline.bold())
                    .lineLimit(1)

                Text(record.direction == .sent ? "Sent" : "Received")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(record.formattedSize)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Color(.label).opacity(0.12), radius: 8, y: 4)
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(record.direction == .sent ? "Sent" : "Received") \(record.fileName), \(record.formattedSize), \(record.success ? "successful" : "failed")")
    }
}
