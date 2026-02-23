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
    @EnvironmentObject private var voicePlayer: VoicePlayer
    @State private var showMediaPreview = false
    @State private var showReactionPicker = false
    var onReaction: ((String) -> Void)?

    init(message: ChatMessage, chatManager: ChatManager? = nil, onReaction: ((String) -> Void)? = nil) {
        self.message = message
        self.chatManager = chatManager
        self.onReaction = onReaction
    }

    private var isVoicePlaying: Bool {
        voicePlayer.isPlaying(messageID: message.id)
    }

    private var isPreviewableMedia: Bool {
        message.mediaType == "image" || message.mediaType == "video"
    }

    var body: some View {
        HStack {
            if message.isOutgoing { Spacer(minLength: 50) }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 4) {
                // Bubble content
                VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 1) {
                    // Reply preview if this is a reply
                    if message.isReply {
                        replyPreview
                    }

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
                .accessibilityElement(children: .combine)
                .accessibilityLabel(bubbleAccessibilityLabel)
                .accessibilityHint("Long press to react")
                .onLongPressGesture {
                    showReactionPicker = true
                }

                // Reactions
                if let reactions = message.reactions, !reactions.isEmpty {
                    ReactionsView(reactions: reactions, isOutgoing: message.isOutgoing)
                }
            }

            if !message.isOutgoing { Spacer(minLength: 50) }
        }
        .padding(.horizontal, 16)
        .padding(message.isOutgoing ? .trailing : .leading, -6)
        .fullScreenCover(isPresented: $showMediaPreview) {
            if let chatManager, isPreviewableMedia {
                MediaPreviewView(message: message, chatManager: chatManager)
            }
        }
        .sheet(isPresented: $showReactionPicker) {
            ReactionPickerView(
                onSelect: { emoji in
                    showReactionPicker = false
                    onReaction?(emoji)
                },
                onDismiss: {
                    showReactionPicker = false
                }
            )
            .presentationDetents([.height(80)])
            .presentationDragIndicator(.hidden)
        }
    }

    // MARK: - Reply Preview

    @ViewBuilder
    private var replyPreview: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(message.isOutgoing ? Color.white.opacity(0.5) : Color.blue)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(replyToSenderDisplayName)
                    .font(.caption.bold())
                    .foregroundStyle(message.isOutgoing ? .white : .blue)

                Text(message.replyToText ?? "")
                    .font(.caption)
                    .foregroundStyle(message.isOutgoing ? .white.opacity(0.8) : .secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(message.isOutgoing ? Color.white.opacity(0.15) : Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.bottom, 4)
    }

    private var replyToSenderDisplayName: String {
        if let name = message.replyToSenderName {
            return name
        }
        return "You"
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
        Group {
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
        .contentShape(Rectangle())
        .accessibilityLabel("Image: \(message.fileName ?? "photo")")
        .accessibilityHint("Double tap to preview")
        .onTapGesture {
            showMediaPreview = true
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
        .contentShape(Rectangle())
        .accessibilityLabel("Video: \(message.fileName ?? "video")")
        .accessibilityHint("Double tap to preview")
        .onTapGesture {
            showMediaPreview = true
        }
    }

    @ViewBuilder
    private var voiceContent: some View {
        HStack(spacing: 8) {
            // Play/Pause button
            Button {
                toggleVoicePlayback()
            } label: {
                Image(systemName: isVoicePlaying ? "pause.fill" : "play.fill")
                    .font(.body)
                    .foregroundStyle(message.isOutgoing ? .white : .primary)
            }
            .accessibilityLabel(isVoicePlaying ? "Pause voice message" : "Play voice message")

            // Waveform bars with progress
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(0..<20, id: \.self) { i in
                        let progress = isVoicePlaying ? playbackProgress : 0
                        let barProgress = Double(i) / 20.0
                        let isPlayed = barProgress < progress

                        RoundedRectangle(cornerRadius: 1)
                            .fill(
                                isPlayed
                                    ? (message.isOutgoing ? Color.white : Color.blue)
                                    : (message.isOutgoing ? Color.white.opacity(0.4) : Color.primary.opacity(0.3))
                            )
                            .frame(width: 2, height: waveformHeight(for: i))
                    }
                }
            }
            .frame(width: 60, height: 20)

            // Duration/Current time
            if isVoicePlaying {
                Text(formatDuration(voicePlayer.currentTime))
                    .font(.caption)
                    .foregroundStyle(message.isOutgoing ? .white.opacity(0.7) : .secondary)
                    .monospacedDigit()
            } else if let duration = message.duration {
                Text(formatDuration(duration))
                    .font(.caption)
                    .foregroundStyle(message.isOutgoing ? .white.opacity(0.7) : .secondary)
            }
        }
        .frame(minWidth: 160)
    }

    private var playbackProgress: Double {
        guard voicePlayer.duration > 0 else { return 0 }
        return voicePlayer.currentTime / voicePlayer.duration
    }

    private func waveformHeight(for index: Int) -> CGFloat {
        // Generate pseudo-random but consistent heights
        let seed = message.id.hashValue + index
        let normalized = abs(sin(Double(seed))) * 0.7 + 0.3
        return CGFloat(normalized) * 16 + 4
    }

    private func toggleVoicePlayback() {
        if isVoicePlaying {
            voicePlayer.togglePlayPause()
            return
        }

        // Stop any current playback
        voicePlayer.stop()

        // Load and play this voice message
        if let localPath = message.localFileURL,
           let chatManager,
           let data = chatManager.loadMediaData(relativePath: localPath) {
            voicePlayer.play(data: data, messageID: message.id)
        }
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

    // MARK: - Accessibility

    private var bubbleAccessibilityLabel: String {
        var parts: [String] = []
        if message.isOutgoing {
            parts.append("Sent")
        } else {
            let senderName = message.senderName ?? message.peerName
            parts.append("From \(senderName)")
        }
        if message.isMedia {
            parts.append(message.mediaType ?? "file")
            if let fileName = message.fileName { parts.append(fileName) }
        } else if let text = message.text {
            parts.append(text)
        }
        switch message.status {
        case .sending: parts.append("sending")
        case .sent: parts.append("sent")
        case .delivered: parts.append("delivered")
        case .read: parts.append("read")
        case .failed: parts.append("failed to send")
        }
        return parts.joined(separator: ", ")
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
