import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import os

private let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "ChatView")

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
    @State private var replyingToMessage: ChatMessage?
    @State private var showMicPermissionAlert = false
    @State private var showSearch = false
    @State private var scrollToMessageID: String?
    @StateObject private var voiceRecorder = VoiceRecorder()

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
                        if chatManager.hasMoreMessages {
                            Button("Load earlier messages") {
                                chatManager.loadMoreMessages()
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                        }

                        ForEach(chatManager.messages) { message in
                            ChatBubbleView(
                                message: message,
                                chatManager: chatManager,
                                onReaction: { emoji in
                                    connectionManager.sendReaction(
                                        emoji: emoji,
                                        to: message.id,
                                        action: .add,
                                        peerID: peerID
                                    )
                                }
                            )
                            .id(message.id)
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    replyingToMessage = message
                                } label: {
                                    Label("Reply", systemImage: "arrowshape.turn.up.left.fill")
                                }
                                .tint(.blue)
                            }
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
                .onChange(of: scrollToMessageID) { messageID in
                    if let messageID {
                        withAnimation {
                            proxy.scrollTo(messageID, anchor: .center)
                        }
                        // Clear after scrolling
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            scrollToMessageID = nil
                        }
                    }
                }
            }

            // Typing indicator
            if chatManager.isTyping(peerID: peerID) {
                TypingIndicatorView(peerName: peerName)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
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

            // Reply preview bar
            if let replyMessage = replyingToMessage {
                replyPreviewBar(for: replyMessage)
            }

            // Input bar
            inputBar
                .disabled(!isPeerConnected)
                .opacity(isPeerConnected ? 1.0 : 0.5)
        }
        .navigationTitle(peerName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSearch = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
            }
        }
        .onAppear {
            chatManager.loadMessages(forPeer: peerID)
            chatManager.activeChatPeerID = peerID
            // Focus on this peer for multi-connection
            connectionManager.focus(on: peerID)
            // Suppress the global error alert while in ChatView (we handle disconnection locally)
            connectionManager.suppressErrorAlert = true
            // Send read receipts for unread messages
            connectionManager.sendReadReceipts(for: peerID)
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
        .alert("Microphone Access Required", isPresented: $showMicPermissionAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Please enable microphone access in Settings to record voice messages.")
        }
        .sheet(isPresented: $showSearch) {
            ChatSearchView(
                chatManager: chatManager,
                peerID: peerID,
                onSelectMessage: { message in
                    scrollToMessageID = message.id
                }
            )
        }
    }

    // MARK: - Reply Preview Bar

    private func replyPreviewBar(for message: ChatMessage) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.blue)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(message.isOutgoing ? "You" : (message.senderName ?? message.peerName))
                    .font(.caption.bold())
                    .foregroundStyle(.blue)

                Text(message.text ?? message.fileName ?? "Media")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                replyingToMessage = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.gray)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        VStack(spacing: 0) {
            // Recording indicator
            if voiceRecorder.isRecording {
                HStack(spacing: 8) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)

                    Text("Recording \(formatDuration(voiceRecorder.duration))")
                        .font(.caption)
                        .foregroundStyle(.red)

                    // Waveform visualization
                    HStack(spacing: 2) {
                        ForEach(0..<15, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color.red.opacity(0.6))
                                .frame(width: 2, height: CGFloat(voiceRecorder.audioLevel * 16 + 4))
                        }
                    }

                    Spacer()

                    // Cancel button
                    Button {
                        voiceRecorder.cancelRecording()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.gray)
                    }
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
                    .onChange(of: messageText) { newValue in
                        connectionManager.handleTypingChange(
                            in: peerID,
                            hasText: !newValue.isEmpty
                        )
                    }

                // Send or Mic button
                if messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        if voiceRecorder.isRecording {
                            stopAndSendVoiceMessage()
                        } else {
                            startVoiceRecording()
                        }
                    } label: {
                        Image(systemName: voiceRecorder.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                            .font(.title2)
                            .foregroundStyle(voiceRecorder.isRecording ? Color.red : Color.gray)
                    }
                    .accessibilityLabel(voiceRecorder.isRecording ? "Stop recording" : "Voice message")
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
        connectionManager.sendTextMessage(text, to: peerID, replyTo: replyingToMessage)
        messageText = ""
        replyingToMessage = nil
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

    // MARK: - Voice recording

    private func startVoiceRecording() {
        Task {
            // Check permission first
            if !VoiceRecorder.hasPermission {
                let granted = await VoiceRecorder.requestPermission()
                if !granted {
                    await MainActor.run {
                        showMicPermissionAlert = true
                    }
                    return
                }
            }

            do {
                try voiceRecorder.startRecording()
            } catch {
                logger.error("Failed to start recording: \(error.localizedDescription)")
            }
        }
    }

    private func stopAndSendVoiceMessage() {
        let duration = voiceRecorder.duration
        guard let url = voiceRecorder.stopRecording() else { return }
        guard duration >= 0.5 else {
            // Ignore very short recordings
            try? FileManager.default.removeItem(at: url)
            return
        }

        // Read the recorded audio data
        guard let data = try? Data(contentsOf: url) else {
            try? FileManager.default.removeItem(at: url)
            return
        }

        let fileName = "Voice_\(Date().timeIntervalSince1970).m4a"
        connectionManager.sendMediaMessage(
            mediaType: .voice,
            fileName: fileName,
            fileData: data,
            mimeType: "audio/mp4",
            duration: duration,
            thumbnailData: nil
        )

        // Clean up temp file
        try? FileManager.default.removeItem(at: url)
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
