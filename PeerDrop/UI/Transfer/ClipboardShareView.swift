import SwiftUI
import UIKit

/// Shows a preview of clipboard content (text or image) and allows quick sharing to the connected peer.
struct ClipboardShareView: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @Environment(\.dismiss) private var dismiss

    @State private var clipboardText: String?
    @State private var clipboardImage: UIImage?
    @State private var isSending = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let text = clipboardText {
                    textPreview(text)
                } else if let image = clipboardImage {
                    imagePreview(image)
                } else {
                    emptyState
                }

                if let error = errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }

                Spacer()

                sendButton
                    .padding(.horizontal)
                    .padding(.bottom)
            }
            .navigationTitle("Share Clipboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { loadClipboard() }
        }
    }

    // MARK: - Subviews

    private func textPreview(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Text", systemImage: "doc.plaintext")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            ScrollView {
                Text(text)
                    .font(.body.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .frame(maxHeight: 300)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
            .accessibilityLabel("Text preview")
            .accessibilityValue(text)

            Text("\(text.count) characters")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal)
        }
        .padding(.top)
    }

    private func imagePreview(_ image: UIImage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Image", systemImage: "photo")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 300)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
                .accessibilityLabel("Image preview")
                .accessibilityValue("\(Int(image.size.width)) by \(Int(image.size.height)) pixels")

            let size = image.pngData().map { Int64($0.count) } ?? 0
            Text("\(Int(image.size.width))x\(Int(image.size.height)) -- \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal)
        }
        .padding(.top)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "clipboard")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text("Nothing to share")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Copy some text or an image to your clipboard first.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private var sendButton: some View {
        Button {
            Task { await send() }
        } label: {
            HStack {
                if isSending {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "paperplane.fill")
                }
                Text(isSending ? "Sending..." : "Send to Peer")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
        .disabled(isSending || (clipboardText == nil && clipboardImage == nil))
        .accessibilityLabel(isSending ? "Sending" : "Send to Peer")
        .accessibilityHint(clipboardText == nil && clipboardImage == nil ? "Copy content to clipboard first" : "Double tap to send clipboard content")
    }

    // MARK: - Logic

    private func loadClipboard() {
        let pasteboard = UIPasteboard.general
        if let string = pasteboard.string, !string.isEmpty {
            clipboardText = string
        } else if let image = pasteboard.image {
            clipboardImage = image
        }
    }

    private func send() async {
        isSending = true
        errorMessage = nil
        HapticManager.tap()

        do {
            let tempURL: URL

            if let text = clipboardText {
                let fileName = "clipboard-\(formatTimestamp()).txt"
                tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
                try text.write(to: tempURL, atomically: true, encoding: .utf8)
            } else if let image = clipboardImage {
                let fileName = "clipboard-\(formatTimestamp()).png"
                tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
                guard let pngData = image.pngData() else {
                    errorMessage = "Failed to encode image"
                    isSending = false
                    return
                }
                try pngData.write(to: tempURL)
            } else {
                isSending = false
                return
            }

            connectionManager.showTransferProgress = true
            connectionManager.transition(to: .transferring(progress: 0))

            try await connectionManager.fileTransfer?.sendFile(at: tempURL)
            connectionManager.transition(to: .connected)
            connectionManager.showTransferProgress = false

            try? FileManager.default.removeItem(at: tempURL)

            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            connectionManager.showTransferProgress = false
            if case .transferring = connectionManager.state {
                connectionManager.transition(to: .connected)
            }
        }

        isSending = false
    }

    private func formatTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
