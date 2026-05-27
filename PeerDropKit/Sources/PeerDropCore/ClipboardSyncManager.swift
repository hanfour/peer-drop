import Foundation
import PeerDropProtocol
import PeerDropPlatform
import Combine
import os.log

@MainActor
public final class ClipboardSyncManager: ObservableObject {
    @Published public private(set) var lastSyncedContent: String?
    @Published public var pendingClipboardContent: ClipboardSyncPayload?

    private let pasteboard: PlatformPasteboard
    private var changeCount: Int
    private var pollTimer: Timer?
    private let maxImageSize: Int = 1_024_000 // 1MB
    private let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "ClipboardSync")

    var onClipboardChanged: ((ClipboardSyncPayload) -> Void)?

    init(pasteboard: PlatformPasteboard = PlatformDependencies.shared.pasteboard()) {
        self.pasteboard = pasteboard
        self.changeCount = pasteboard.changeCount
    }

    public func startMonitoring() {
        guard FeatureSettings.isClipboardSyncEnabled else { return }
        stopMonitoring()

        changeCount = pasteboard.changeCount

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pasteboardChanged),
            name: pasteboard.changedNotificationName,
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

    public func stopMonitoring() {
        NotificationCenter.default.removeObserver(self, name: pasteboard.changedNotificationName, object: nil)
        pollTimer?.invalidate()
        pollTimer = nil
    }

    @objc private func pasteboardChanged() {
        Task { @MainActor in
            checkPasteboardChange()
        }
    }

    private func checkPasteboardChange() {
        let currentCount = pasteboard.changeCount
        guard currentCount != changeCount else { return }
        changeCount = currentCount

        guard FeatureSettings.isClipboardSyncEnabled else { return }

        if let payload = buildPayload() {
            pendingClipboardContent = payload
            onClipboardChanged?(payload)
        }
    }

    private func buildPayload() -> ClipboardSyncPayload? {
        if let string = pasteboard.stringContent, !string.isEmpty {
            if let url = URL(string: string), url.scheme != nil {
                return ClipboardSyncPayload(contentType: .url, textContent: string)
            }
            return ClipboardSyncPayload(contentType: .text, textContent: string)
        }

        if let image = pasteboard.imageContent,
           let data = image.platformJPEGData(compressionQuality: 0.7) {
            if data.count <= maxImageSize {
                return ClipboardSyncPayload(contentType: .image, imageData: data)
            } else {
                // Try lower quality
                if let compressed = image.platformJPEGData(compressionQuality: 0.3),
                   compressed.count <= maxImageSize {
                    return ClipboardSyncPayload(contentType: .image, imageData: compressed)
                }
                logger.warning("Clipboard image too large to sync (\(data.count) bytes)")
            }
        }

        return nil
    }

    public func applyReceivedClipboard(_ payload: ClipboardSyncPayload) {
        switch payload.contentType {
        case .text, .url:
            if let text = payload.textContent {
                pasteboard.stringContent = text
                lastSyncedContent = text
                // Update changeCount so we don't re-broadcast what we just received
                changeCount = pasteboard.changeCount
            }
        case .image:
            if let data = payload.imageData, let image = PlatformImage(data: data) {
                pasteboard.imageContent = image
                lastSyncedContent = "[\(NSLocalizedString("Image", comment: ""))]"
                changeCount = pasteboard.changeCount
            }
        }
    }

    public func clearPending() {
        pendingClipboardContent = nil
    }

    deinit {
        pollTimer?.invalidate()
    }
}
