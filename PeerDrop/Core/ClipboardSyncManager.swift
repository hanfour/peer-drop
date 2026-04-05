import UIKit
import Combine
import os.log

@MainActor
final class ClipboardSyncManager: ObservableObject {
    @Published private(set) var lastSyncedContent: String?
    @Published var pendingClipboardContent: ClipboardSyncPayload?

    private var changeCount: Int = UIPasteboard.general.changeCount
    private var pollTimer: Timer?
    private let maxImageSize: Int = 1_024_000 // 1MB
    private let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "ClipboardSync")

    var onClipboardChanged: ((ClipboardSyncPayload) -> Void)?

    func startMonitoring() {
        guard FeatureSettings.isClipboardSyncEnabled else { return }
        stopMonitoring()

        changeCount = UIPasteboard.general.changeCount

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pasteboardChanged),
            name: UIPasteboard.changedNotification,
            object: nil
        )

        // Poll as fallback since changedNotification isn't always reliable in background
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkPasteboardChange()
            }
        }

        logger.info("Clipboard sync monitoring started")
    }

    func stopMonitoring() {
        NotificationCenter.default.removeObserver(self, name: UIPasteboard.changedNotification, object: nil)
        pollTimer?.invalidate()
        pollTimer = nil
    }

    @objc private func pasteboardChanged() {
        Task { @MainActor in
            checkPasteboardChange()
        }
    }

    private func checkPasteboardChange() {
        let currentCount = UIPasteboard.general.changeCount
        guard currentCount != changeCount else { return }
        changeCount = currentCount

        guard FeatureSettings.isClipboardSyncEnabled else { return }

        if let payload = buildPayload() {
            pendingClipboardContent = payload
            onClipboardChanged?(payload)
        }
    }

    private func buildPayload() -> ClipboardSyncPayload? {
        let pasteboard = UIPasteboard.general

        if let string = pasteboard.string, !string.isEmpty {
            if let url = URL(string: string), url.scheme != nil {
                return ClipboardSyncPayload(contentType: .url, textContent: string)
            }
            return ClipboardSyncPayload(contentType: .text, textContent: string)
        }

        if let image = pasteboard.image,
           let data = image.jpegData(compressionQuality: 0.7) {
            if data.count <= maxImageSize {
                return ClipboardSyncPayload(contentType: .image, imageData: data)
            } else {
                // Try lower quality
                if let compressed = image.jpegData(compressionQuality: 0.3),
                   compressed.count <= maxImageSize {
                    return ClipboardSyncPayload(contentType: .image, imageData: compressed)
                }
                logger.warning("Clipboard image too large to sync (\(data.count) bytes)")
            }
        }

        return nil
    }

    func applyReceivedClipboard(_ payload: ClipboardSyncPayload) {
        switch payload.contentType {
        case .text, .url:
            if let text = payload.textContent {
                UIPasteboard.general.string = text
                lastSyncedContent = text
                // Update changeCount so we don't re-broadcast what we just received
                changeCount = UIPasteboard.general.changeCount
            }
        case .image:
            if let data = payload.imageData, let image = UIImage(data: data) {
                UIPasteboard.general.image = image
                lastSyncedContent = "[\(NSLocalizedString("Image", comment: ""))]"
                changeCount = UIPasteboard.general.changeCount
            }
        }
    }

    func clearPending() {
        pendingClipboardContent = nil
    }

    deinit {
        pollTimer?.invalidate()
    }
}
