import SwiftUI
import PeerDropCore
import PeerDropTransport
import PeerDropPlatform
#if os(iOS)
import QuickLook
#endif

// MARK: - iMessage-style bubble shape

struct MessageBubbleShape: Shape {
    let isOutgoing: Bool
    let cornerRadius: CGFloat = 18

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let r = cornerRadius
        // The tail-side bottom corner gets a tighter radius
        let tailR: CGFloat = 6

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
    @State private var previewFileURL: URL?
    @State private var showReactionPicker = false
    @State private var showEditSheet = false
    @State private var editText = ""
    var onReaction: ((String) -> Void)?
    var onEdit: ((String, String) -> Void)?
    var onDelete: ((String) -> Void)?
    let runStart: Bool
    let senderFallbackName: String
    /// The peer's current name from the live connection; wins over the name stored
    /// with the message (identity is fixed at handshake, so stored names can be old or blank).
    let liveSenderName: String?

    init(message: ChatMessage, chatManager: ChatManager? = nil, runStart: Bool = true, senderFallbackName: String = String(localized: "Other person"), liveSenderName: String? = nil, onReaction: ((String) -> Void)? = nil, onEdit: ((String, String) -> Void)? = nil, onDelete: ((String) -> Void)? = nil) {
        self.runStart = runStart
        self.senderFallbackName = senderFallbackName
        self.liveSenderName = liveSenderName
        self.message = message
        self.chatManager = chatManager
        self.onReaction = onReaction
        self.onEdit = onEdit
        self.onDelete = onDelete
    }

    private var isVoicePlaying: Bool {
        voicePlayer.isPlaying(messageID: message.id)
    }

    private var isPreviewableMedia: Bool {
        message.mediaType == "image" || message.mediaType == "video"
    }

    var body: some View {
        HStack(alignment: .top) {
            if message.isOutgoing { Spacer(minLength: 50) }

            if !message.isOutgoing {
                ChatAvatarSlot(name: senderDisplayName, visible: runStart)
            }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 4) {
                if !message.isOutgoing && runStart {
                    Text(senderDisplayName)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(PaperTheme.color(.datePillText))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.leading, 4)
                        .accessibilityHidden(true)
                }

                // Bubble content
                VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 1) {
                    // Reply preview if this is a reply
                    if message.isReply {
                        replyPreview
                    }

                    // Content
                    if message.isDeleted {
                        HStack(spacing: 4) {
                            Image(systemName: "nosign")
                                .font(.caption)
                            Text("Message deleted")
                                .italic()
                        }
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(textColor.opacity(0.6))
                    } else if message.isMedia {
                        mediaContent
                    } else {
                        Text(message.text ?? "")
                            .font(.system(.body, design: .rounded))
                            .foregroundStyle(textColor)
                    }

                    // Timestamp + edited label + status inline
                    HStack(spacing: 3) {
                        if message.editedAt != nil {
                            Text("edited")
                                .font(.system(size: 10, design: .rounded))
                                .italic()
                                .foregroundStyle(textColor.opacity(0.6))
                        }

                        Text(message.timestamp, style: .time)
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(textColor.opacity(0.7))

                        if message.isOutgoing {
                            statusView
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(bubbleColor)
                .clipShape(MessageBubbleShape(isOutgoing: message.isOutgoing))
                .overlay {
                    if !message.isOutgoing {
                        MessageBubbleShape(isOutgoing: false)
                            .stroke(PaperTheme.color(.border), lineWidth: 1)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(bubbleAccessibilityLabel)
                .accessibilityHint("Long press to react")
                .contextMenu {
                    Button {
                        showReactionPicker = true
                    } label: {
                        Label("React", systemImage: "face.smiling")
                    }

                    if message.canEditOrDelete {
                        Button {
                            editText = message.text ?? ""
                            showEditSheet = true
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }

                        Button(role: .destructive) {
                            onDelete?(message.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
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
        #if os(iOS)
        .fullScreenCover(isPresented: $showMediaPreview) {
            if let chatManager, isPreviewableMedia {
                MediaPreviewView(message: message, chatManager: chatManager)
            }
        }
        // QuickLook, not a ShareSheet wrapped in .sheet: UIActivityViewController
        // presents itself, so nesting it in a SwiftUI sheet showed a blank panel
        // for a long time. QuickLook previews PDFs/docs/images and has its own share button.
        .quickLookPreview($previewFileURL)
        #else
        .sheet(isPresented: $showMediaPreview) {
            if let chatManager, isPreviewableMedia {
                MediaPreviewView(message: message, chatManager: chatManager)
            }
        }
        #endif
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
        .sheet(isPresented: $showEditSheet) {
            NavigationStack {
                VStack {
                    TextField("Message", text: $editText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .padding()
                    Spacer()
                }
                .navigationTitle("Edit Message")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showEditSheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                onEdit?(message.id, trimmed)
                            }
                            showEditSheet = false
                        }
                        .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }

    private var senderDisplayName: String {
        ChatDisplayName.preferred(liveSenderName, message.peerName) ?? senderFallbackName
    }

    // MARK: - Reply Preview

    @ViewBuilder
    private var replyPreview: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(PaperTheme.color(.quoteBar))
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(replyToSenderDisplayName)
                    .font(.system(.caption, design: .rounded).bold())
                    .foregroundStyle(textColor)

                Text(message.replyToText ?? "")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(textColor.opacity(0.8))
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(textColor.opacity(0.10))
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

    private var textColor: Color {
        PaperTheme.color(message.isOutgoing ? .outgoingText : .incomingText)
    }

    private var bubbleColor: Color {
        PaperTheme.color(message.isOutgoing ? .outgoingBubble : .incomingBubble)
    }

    // MARK: - Status view

    @ViewBuilder
    private var statusView: some View {
        switch message.status {
        case .sending:
            ProgressView()
                .tint(textColor)
                .scaleEffect(0.4)
                .frame(width: 10, height: 10)
        case .sent:
            Image(systemName: "checkmark")
                .font(.system(size: 9))
                .foregroundStyle(PaperTheme.color(PaperTheme.tick(for: message.status)))
        case .delivered:
            HStack(spacing: -4) {
                Image(systemName: "checkmark")
                Image(systemName: "checkmark")
            }
            .font(.system(size: 9))
            .foregroundStyle(PaperTheme.color(PaperTheme.tick(for: message.status)))
        case .read:
            HStack(spacing: -4) {
                Image(systemName: "checkmark")
                Image(systemName: "checkmark")
            }
            .font(.system(size: 9))
            .foregroundStyle(PaperTheme.color(PaperTheme.tick(for: message.status)))
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(PaperTheme.color(PaperTheme.tick(for: message.status)))
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
            if let cached = ImageCache.shared.image(forKey: message.id) {
                Image(platformImage: cached)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 220, maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else if let thumbData = message.thumbnailData, let platformImage = PlatformImage(data: thumbData) {
                Image(platformImage: platformImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 220, maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .onAppear { ImageCache.shared.setImage(platformImage, forKey: message.id) }
            } else if let localPath = message.localFileURL,
                      let chatManager,
                      let mediaData = chatManager.loadMediaData(relativePath: localPath),
                      let platformImage = PlatformImage(data: mediaData) {
                Image(platformImage: platformImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 220, maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .onAppear { ImageCache.shared.setImage(platformImage, forKey: message.id) }
            } else {
                Label(message.fileName ?? "Image", systemImage: "photo")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(textColor)
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
            if let thumbData = message.thumbnailData, let platformImage = PlatformImage(data: thumbData) {
                Image(platformImage: platformImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 220, maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.peerDropFillPrimary)
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
                    .foregroundStyle(textColor)
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
                                    ? textColor
                                    : textColor.opacity(0.3)
                            )
                            .frame(width: 2, height: waveformHeight(for: i))
                    }
                }
            }
            // 20 bars x 2pt + 19 gaps x 2pt = 78pt; reserve exactly that so the bars never
            // reach the duration label.
            .frame(width: 78, height: 20)

            // Duration/Current time
            if isVoicePlaying {
                Text(formatDuration(voicePlayer.currentTime))
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(textColor.opacity(0.7))
                    .monospacedDigit()
            } else if let duration = message.duration {
                Text(formatDuration(duration))
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(textColor.opacity(0.7))
            }
        }
        .frame(minWidth: 160)
    }

    private var playbackProgress: Double {
        guard voicePlayer.duration > 0 else { return 0 }
        return voicePlayer.currentTime / voicePlayer.duration
    }

    private func waveformHeight(for index: Int) -> CGFloat {
        VoiceWaveform.height(forMessageID: message.id, index: index)
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
                .foregroundStyle(textColor.opacity(0.8))

            VStack(alignment: .leading, spacing: 2) {
                Text(message.fileName ?? "File")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(textColor)
                    .lineLimit(1)

                if let size = message.fileSize {
                    Text(formatFileSize(size))
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(textColor.opacity(0.7))
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityHint("Double tap to open")
        .onTapGesture { openFile() }
    }

    /// Opens a received/sent file attachment. The stored copy is encrypted at
    /// rest, so it is decrypted to a temp file first; macOS opens it in the
    /// default app, iOS previews it with QuickLook (which also offers share / save to Files).
    private func openFile() {
        guard let chatManager, let localPath = message.localFileURL,
              let url = chatManager.writeMediaToTempFile(relativePath: localPath),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else { return }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        previewFileURL = url
        #endif
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

/// Stable (per message id) pseudo-random bar heights for the voice waveform.
enum VoiceWaveform {
    static func height(forMessageID id: String, index: Int) -> CGFloat {
        let seed = Double(Int(StableHash.fnv1a32(id.utf8) % 100_000) + index)
        let normalized = abs(sin(seed)) * 0.7 + 0.3
        return CGFloat(normalized) * 16 + 4
    }
}
