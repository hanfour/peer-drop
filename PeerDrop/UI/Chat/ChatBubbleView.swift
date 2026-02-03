import SwiftUI

struct ChatBubbleView: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.isOutgoing { Spacer() }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 4) {
                if message.isMedia {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.fill")
                            .font(.caption)
                        Text(message.fileName ?? "Media")
                            .font(.subheadline)
                    }
                } else {
                    Text(message.text ?? "")
                        .font(.body)
                }

                HStack(spacing: 4) {
                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if message.isOutgoing {
                        Image(systemName: statusIcon)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(message.isOutgoing ? Color.blue.opacity(0.2) : Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))

            if !message.isOutgoing { Spacer() }
        }
    }

    private var statusIcon: String {
        switch message.status {
        case .sending: return "clock"
        case .sent: return "checkmark"
        case .delivered: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle"
        }
    }
}
