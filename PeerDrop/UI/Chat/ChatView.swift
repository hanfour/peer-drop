import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

struct ChatView: View {
    @ObservedObject var chatManager: ChatManager
    let peerID: String
    let peerName: String
    var onBack: (() -> Void)?
    @EnvironmentObject var connectionManager: ConnectionManager

    @State private var messageText = ""
    @State private var showAttachmentMenu = false
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var showDocumentPicker = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var isRecordingVoice = false
    @State private var voiceRecordingDuration: TimeInterval = 0
    @State private var voiceRecordingTimer: Timer?

    /// Check if this specific peer is connected (multi-connection aware).
    private var isPeerConnected: Bool {
        if let peerConn = connectionManager.connection(for: peerID) {
            return peerConn.state.isConnected
        }
        // Fallback to global state for backward compatibility
        switch connectionManager.state {
        case .connected, .transferring, .voiceCall:
            return connectionManager.connectedPeer?.id == peerID
        default:
            return false
        }
    }

    /// Check if this peer is disconnected.
    private var isPeerDisconnected: Bool {
        if let peerConn = connectionManager.connection(for: peerID) {
            switch peerConn.state {
            case .disconnected, .failed:
                return true
            default:
                return false
            }
        }
        // Fallback to global state
        switch connectionManager.state {
        case .failed, .disconnected:
            return true
        default:
            return false
        }
    }

    /// Get disconnect reason for this peer.
    private var disconnectReason: String? {
        if let peerConn = connectionManager.connection(for: peerID) {
            if case .failed(let reason) = peerConn.state {
                return reason
            }
        }
        if case .failed(let reason) = connectionManager.state {
            return reason
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(chatManager.messages) { message in
                            ChatBubbleView(message: message, chatManager: chatManager)
                                .id(message.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 12)
                }
                .onChange(of: chatManager.messages.count) { _ in
                    if let last = chatManager.messages.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Disconnected banner with reconnect option
            if isPeerDisconnected {
                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "wifi.exclamationmark")
                            .foregroundStyle(.orange)
                        Text(disconnectReason ?? "Connection lost")
                            .font(.subheadline.weight(.medium))
                    }

                    HStack(spacing: 16) {
                        Button {
                            connectionManager.reconnect(to: peerID)
                        } label: {
                            Label("Reconnect", systemImage: "arrow.triangle.2.circlepath")
                                .font(.subheadline.weight(.medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)

                        Button {
                            // Navigate back and return to discovery
                            connectionManager.returnToDiscovery()
                        } label: {
                            Text("Back to Nearby")
                                .font(.subheadline)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .background(Color(.systemGray6))
            }

            // Input bar
            inputBar
                .disabled(!isPeerConnected)
                .opacity(isPeerConnected ? 1.0 : 0.5)
        }
        .navigationTitle(peerName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            chatManager.loadMessages(forPeer: peerID)
            chatManager.activeChatPeerID = peerID
            // Focus on this peer for multi-connection
            connectionManager.focus(on: peerID)
            // Suppress the global error alert while in ChatView (we handle disconnection locally)
            connectionManager.suppressErrorAlert = true
        }
        .onDisappear {
            chatManager.activeChatPeerID = nil
            connectionManager.suppressErrorAlert = false
        }
        .sheet(isPresented: $showAttachmentMenu) {
            AttachmentMenuSheet(
                onCamera: { showAttachmentMenu = false; showCamera = true },
                onPhotos: { showAttachmentMenu = false; showPhotoPicker = true },
                onFiles: { showAttachmentMenu = false; showDocumentPicker = true }
            )
            .presentationDetents([.height(280)])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPickerView { image in
                sendImage(image)
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotoItems, maxSelectionCount: 5, matching: .any(of: [.images, .videos]))
        .onChange(of: selectedPhotoItems) { items in
            Task { await handleSelectedPhotos(items) }
        }
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPickerView { urls in
                for url in urls {
                    sendFile(url)
                }
            }
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        VStack(spacing: 0) {
            // Recording indicator
            if isRecordingVoice {
                HStack(spacing: 8) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                    Text("Recording \(formatDuration(voiceRecordingDuration))")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
            }

            HStack(spacing: 8) {
                // + Attachment button
                Button {
                    showAttachmentMenu = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.gray)
                }
                .accessibilityLabel("Attach")

                // Text field
                TextField("Message", text: $messageText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6))
                    .clipShape(Capsule())

                // Send or Mic button
                if messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        if isRecordingVoice {
                            stopAndSendVoiceMessage()
                        } else {
                            startVoiceRecording()
                        }
                    } label: {
                        Image(systemName: isRecordingVoice ? "stop.circle.fill" : "mic.circle.fill")
                            .font(.title2)
                            .foregroundStyle(isRecordingVoice ? Color.red : Color.gray)
                    }
                    .accessibilityLabel(isRecordingVoice ? "Stop recording" : "Voice message")
                } else {
                    Button {
                        sendMessage()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.green)
                    }
                    .accessibilityLabel("Send")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Send text

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Use per-peer send for multi-connection
        connectionManager.sendTextMessage(text, to: peerID)
        messageText = ""
    }

    // MARK: - Send image

    private func sendImage(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.8) else { return }
        let fileName = "IMG_\(Date().timeIntervalSince1970).jpg"
        let thumbData = makeThumbnail(image, maxSize: 200)

        connectionManager.sendMediaMessage(
            mediaType: .image,
            fileName: fileName,
            fileData: data,
            mimeType: "image/jpeg",
            duration: nil,
            thumbnailData: thumbData
        )
    }

    // MARK: - Handle photo picker

    private func handleSelectedPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) {
                let fileName = "Photo_\(Date().timeIntervalSince1970).jpg"
                let thumbData = UIImage(data: data).flatMap { self.makeThumbnail($0, maxSize: 200) }

                await MainActor.run {
                    connectionManager.sendMediaMessage(
                        mediaType: .image,
                        fileName: fileName,
                        fileData: data,
                        mimeType: "image/jpeg",
                        duration: nil,
                        thumbnailData: thumbData
                    )
                }
            }
        }
        await MainActor.run { selectedPhotoItems = [] }
    }

    // MARK: - Send file

    private func sendFile(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        guard let data = try? Data(contentsOf: url) else { return }
        let fileName = url.lastPathComponent
        let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"

        connectionManager.sendMediaMessage(
            mediaType: .file,
            fileName: fileName,
            fileData: data,
            mimeType: mimeType,
            duration: nil,
            thumbnailData: nil
        )
    }

    // MARK: - Voice recording (simplified — saves silent placeholder for now)

    private func startVoiceRecording() {
        isRecordingVoice = true
        voiceRecordingDuration = 0
        voiceRecordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                voiceRecordingDuration += 0.1
            }
        }
    }

    private func stopAndSendVoiceMessage() {
        isRecordingVoice = false
        voiceRecordingTimer?.invalidate()
        voiceRecordingTimer = nil

        let duration = voiceRecordingDuration
        guard duration >= 0.5 else { return } // Ignore very short recordings

        // Placeholder: send a voice message record (actual AVAudioRecorder integration is separate)
        let fileName = "Voice_\(Date().timeIntervalSince1970).m4a"
        connectionManager.sendMediaMessage(
            mediaType: .voice,
            fileName: fileName,
            fileData: Data(),
            mimeType: "audio/mp4",
            duration: duration,
            thumbnailData: nil
        )
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func makeThumbnail(_ image: UIImage, maxSize: CGFloat) -> Data? {
        let scale = min(maxSize / image.size.width, maxSize / image.size.height, 1.0)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let thumb = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return thumb.jpegData(compressionQuality: 0.6)
    }
}

// MARK: - Document Picker

struct DocumentPickerView: UIViewControllerRepresentable {
    var onDocumentsPicked: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item])
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onDocumentsPicked: onDocumentsPicked)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onDocumentsPicked: ([URL]) -> Void

        init(onDocumentsPicked: @escaping ([URL]) -> Void) {
            self.onDocumentsPicked = onDocumentsPicked
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onDocumentsPicked(urls)
        }
    }
}

// MARK: - iMessage-style Attachment Menu

struct AttachmentMenuSheet: View {
    let onCamera: () -> Void
    let onPhotos: () -> Void
    let onFiles: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(menuItems, id: \.label) { item in
                Button(action: item.action) {
                    HStack(spacing: 16) {
                        Image(systemName: item.icon)
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(item.color)
                            .clipShape(Circle())

                        Text(item.label)
                            .font(.body)
                            .foregroundStyle(.primary)

                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }

                if item.label != menuItems.last?.label {
                    Divider().padding(.leading, 76)
                }
            }
        }
        .padding(.top, 8)
    }

    private var menuItems: [MenuItem] {
        [
            MenuItem(icon: "camera.fill", label: "Camera", color: .gray, action: onCamera),
            MenuItem(icon: "photo.on.rectangle", label: "Photos", color: Color(red: 0.0, green: 0.68, blue: 1.0), action: onPhotos),
            MenuItem(icon: "doc.fill", label: "Files", color: Color(red: 0.33, green: 0.33, blue: 0.98), action: onFiles),
        ]
    }

    private struct MenuItem {
        let icon: String
        let label: String
        let color: Color
        let action: () -> Void
    }
}
