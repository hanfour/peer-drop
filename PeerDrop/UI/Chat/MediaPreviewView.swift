import SwiftUI
import AVKit

/// Full-screen media preview for images and videos.
struct MediaPreviewView: View {
    let message: ChatMessage
    let chatManager: ChatManager

    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var player: AVPlayer?

    private var isVideo: Bool {
        message.mediaType == "video"
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()

                if isVideo {
                    videoView(in: geometry)
                } else {
                    imageView(in: geometry)
                }
            }
            .overlay(alignment: .topTrailing) {
                closeButton
            }
            .overlay(alignment: .bottom) {
                infoBar
            }
        }
        .statusBar(hidden: true)
        .onAppear {
            if isVideo {
                setupVideoPlayer()
            }
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    // MARK: - Close Button

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.title)
                .foregroundStyle(.white.opacity(0.8))
                .shadow(radius: 4)
        }
        .padding()
    }

    // MARK: - Info Bar

    private var infoBar: some View {
        VStack(spacing: 4) {
            if let fileName = message.fileName {
                Text(fileName)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
            }

            Text(message.timestamp, style: .date) + Text(" ") + Text(message.timestamp, style: .time)
        }
        .font(.caption2)
        .foregroundStyle(.white.opacity(0.6))
        .padding()
        .background(.ultraThinMaterial.opacity(0.5))
    }

    // MARK: - Image View

    @ViewBuilder
    private func imageView(in geometry: GeometryProxy) -> some View {
        if let image = loadImage() {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            scale = lastScale * value
                        }
                        .onEnded { _ in
                            withAnimation(.spring()) {
                                if scale < 1.0 {
                                    scale = 1.0
                                    offset = .zero
                                } else if scale > 4.0 {
                                    scale = 4.0
                                }
                                lastScale = scale
                            }
                        }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            if scale > 1.0 {
                                offset = CGSize(
                                    width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height
                                )
                            } else {
                                // Dismiss on drag down when not zoomed
                                if value.translation.height > 100 {
                                    dismiss()
                                }
                            }
                        }
                        .onEnded { _ in
                            lastOffset = offset
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.spring()) {
                        if scale > 1.0 {
                            scale = 1.0
                            offset = .zero
                            lastScale = 1.0
                            lastOffset = .zero
                        } else {
                            scale = 2.5
                            lastScale = 2.5
                        }
                    }
                }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.white.opacity(0.6))
                Text("Image Unavailable")
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    // MARK: - Video View

    @ViewBuilder
    private func videoView(in geometry: GeometryProxy) -> some View {
        if let player {
            VideoPlayer(player: player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onTapGesture {
                    if player.timeControlStatus == .playing {
                        player.pause()
                    } else {
                        player.play()
                    }
                }
        } else {
            ProgressView()
                .tint(.white)
        }
    }

    // MARK: - Helpers

    private func loadImage() -> UIImage? {
        // Try thumbnail first for quick display
        if let thumbData = message.thumbnailData, let image = UIImage(data: thumbData) {
            // If we have local file, load full resolution
            if let localPath = message.localFileURL,
               let mediaData = chatManager.loadMediaData(relativePath: localPath),
               let fullImage = UIImage(data: mediaData) {
                return fullImage
            }
            return image
        }

        // Load from local file
        if let localPath = message.localFileURL,
           let mediaData = chatManager.loadMediaData(relativePath: localPath),
           let image = UIImage(data: mediaData) {
            return image
        }

        return nil
    }

    private func setupVideoPlayer() {
        guard let localPath = message.localFileURL else { return }

        // Write to temp file for playback
        if let url = chatManager.writeMediaToTempFile(relativePath: localPath) {
            player = AVPlayer(url: url)
            player?.play()
        }
    }
}
