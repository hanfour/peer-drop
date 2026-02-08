import SwiftUI

// MARK: - iMessage-style bubble shape

struct MessageBubbleShape: Shape {
    let isOutgoing: Bool
    let cornerRadius: CGFloat = 18

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let r = cornerRadius
        // The tail-side bottom corner gets a tighter radius
        let tailR: CGFloat = 2

        var path = Path()

        if isOutgoing {
            // Start top-left
            path.move(to: CGPoint(x: r, y: 0))
            // Top edge
            path.addLine(to: CGPoint(x: w - r, y: 0))
            // Top-right corner
            path.addArc(center: CGPoint(x: w - r, y: r), radius: r,
                        startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
            // Right edge down to bottom-right (tight corner for tail)
            path.addLine(to: CGPoint(x: w, y: h - tailR))
            // Bottom-right: tight corner (tail side)
            path.addArc(center: CGPoint(x: w - tailR, y: h - tailR), radius: tailR,
                        startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            // Bottom edge
            path.addLine(to: CGPoint(x: r, y: h))
            // Bottom-left corner
            path.addArc(center: CGPoint(x: r, y: h - r), radius: r,
                        startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            // Left edge
            path.addLine(to: CGPoint(x: 0, y: r))
            // Top-left corner
            path.addArc(center: CGPoint(x: r, y: r), radius: r,
                        startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        } else {
            // Start top-left
            path.move(to: CGPoint(x: r, y: 0))
            // Top edge
            path.addLine(to: CGPoint(x: w - r, y: 0))
            // Top-right corner
            path.addArc(center: CGPoint(x: w - r, y: r), radius: r,
                        startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
            // Right edge
            path.addLine(to: CGPoint(x: w, y: h - r))
            // Bottom-right corner
            path.addArc(center: CGPoint(x: w - r, y: h - r), radius: r,
                        startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            // Bottom edge
            path.addLine(to: CGPoint(x: tailR, y: h))
            // Bottom-left: tight corner (tail side)
            path.addArc(center: CGPoint(x: tailR, y: h - tailR), radius: tailR,
                        startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            // Left edge
            path.addLine(to: CGPoint(x: 0, y: r))
            // Top-left corner
            path.addArc(center: CGPoint(x: r, y: r), radius: r,
                        startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        }

        path.closeSubpath()
        return path
    }
}

// MARK: - Chat Bubble

struct ChatBubbleView: View {
    let message: ChatMessage
    let chatManager: ChatManager?

    init(message: ChatMessage, chatManager: ChatManager? = nil) {
        self.message = message
        self.chatManager = chatManager
    }

    var body: some View {
        HStack {
            if message.isOutgoing { Spacer(minLength: 50) }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 1) {
                // Content
                if message.isMedia {
                    mediaContent
                } else {
                    Text(message.text ?? "")
                        .font(.body)
                        .foregroundStyle(message.isOutgoing ? .white : .primary)
                }

                // Timestamp + status inline
                HStack(spacing: 3) {
                    Text(message.timestamp, style: .time)
                        .font(.system(size: 11))
                        .foregroundStyle(message.isOutgoing ? .white.opacity(0.65) : .secondary)

                    if message.isOutgoing {
                        statusView
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(bubbleColor)
            .clipShape(MessageBubbleShape(isOutgoing: message.isOutgoing))

            if !message.isOutgoing { Spacer(minLength: 50) }
        }
        .padding(.horizontal, 16)
        .padding(message.isOutgoing ? .trailing : .leading, -6)
    }

    // MARK: - Bubble color

    private var bubbleColor: Color {
        message.isOutgoing ? Color(red: 0.21, green: 0.78, blue: 0.35) : Color(.systemGray5)
    }

    // MARK: - Status view

    @ViewBuilder
    private var statusView: some View {
        switch message.status {
        case .sending:
            ProgressView()
                .scaleEffect(0.4)
                .frame(width: 10, height: 10)
        case .sent:
            Image(systemName: "checkmark")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.65))
        case .delivered:
            HStack(spacing: -4) {
                Image(systemName: "checkmark")
                Image(systemName: "checkmark")
            }
            .font(.system(size: 9))
            .foregroundStyle(.white.opacity(0.65))
        case .read:
            HStack(spacing: -4) {
                Image(systemName: "checkmark")
                Image(systemName: "checkmark")
            }
            .font(.system(size: 9))
            .foregroundStyle(.cyan)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
        }
    }

    // MARK: - Media content

    @ViewBuilder
    private var mediaContent: some View {
        switch message.mediaType {
        case "image":
            imageContent
        case "video":
            videoContent
        case "voice":
            voiceContent
        default:
            fileContent
        }
    }

    @ViewBuilder
    private var imageContent: some View {
        if let thumbData = message.thumbnailData, let uiImage = UIImage(data: thumbData) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 220, maxHeight: 220)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else if let localPath = message.localFileURL,
                  let chatManager,
                  let mediaData = chatManager.loadMediaData(relativePath: localPath),
                  let uiImage = UIImage(data: mediaData) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 220, maxHeight: 220)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            Label(message.fileName ?? "Image", systemImage: "photo")
                .font(.subheadline)
                .foregroundStyle(message.isOutgoing ? .white : .primary)
        }
    }

    @ViewBuilder
    private var videoContent: some View {
        ZStack {
            if let thumbData = message.thumbnailData, let uiImage = UIImage(data: thumbData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 220, maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemGray4))
                    .frame(width: 200, height: 120)
            }
            Image(systemName: "play.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(.white)
                .shadow(radius: 4)
        }
    }

    @ViewBuilder
    private var voiceContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "play.fill")
                .font(.caption)
                .foregroundStyle(message.isOutgoing ? .white : .primary)

            // Waveform bars
            HStack(spacing: 2) {
                ForEach(0..<20, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(message.isOutgoing ? Color.white.opacity(0.7) : Color.primary.opacity(0.4))
                        .frame(width: 2, height: CGFloat.random(in: 4...16))
                }
            }

            if let duration = message.duration {
                Text(formatDuration(duration))
                    .font(.caption)
                    .foregroundStyle(message.isOutgoing ? .white.opacity(0.7) : .secondary)
            }
        }
        .frame(minWidth: 140)
    }

    @ViewBuilder
    private var fileContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.fill")
                .font(.title3)
                .foregroundStyle(message.isOutgoing ? .white.opacity(0.8) : .blue)

            VStack(alignment: .leading, spacing: 2) {
                Text(message.fileName ?? "File")
                    .font(.subheadline)
                    .foregroundStyle(message.isOutgoing ? .white : .primary)
                    .lineLimit(1)

                if let size = message.fileSize {
                    Text(formatFileSize(size))
                        .font(.caption2)
                        .foregroundStyle(message.isOutgoing ? .white.opacity(0.7) : .secondary)
                }
            }
        }
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
