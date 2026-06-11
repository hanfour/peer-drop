#if canImport(AppKit)
import AppKit
import Foundation
import PeerDropCore
import PeerDropTransport
import os

/// Shared drop logic for Dock / main-window / menu-bar drop sites.
///
/// Round 6 audit fix: previously a logging-only stub. Now actually
/// sends files via `connectionManager.fileTransfer?.sendFiles(…)` after
/// the user confirms in an NSAlert. App Review compliance preserved —
/// drops never send silently; the confirmation alert lists the target
/// peer's display name and the files being sent.
///
/// Three entry points:
///   1. `handle(urls:)` — generic drop (Dock icon, main window). Picks
///      the target peer from `discoveredPeers` (or shows "connect a peer
///      first" if none).
///   2. `handle(urls:toPeerID:)` — per-peer drop (menu-bar row).
///      Skips peer selection; goes straight to confirmation.
@MainActor
enum MacDropHandler {
    private static let logger = Logger(subsystem: "com.hanfour.peerdrop.mac", category: "MacDropHandler")

    /// Wired by `PeerDropMacApp.onAppear`. `weak` so MacDropHandler
    /// doesn't extend the lifetime of the SwiftUI-owned
    /// ConnectionManager beyond the app shell's scope.
    static weak var connectionManager: ConnectionManager?

    @discardableResult
    static func handle(urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        logger.info("Drop received (no peer hint): \(urls.map(\.lastPathComponent).joined(separator: ", "), privacy: .public)")

        guard let connectionManager else {
            logger.error("MacDropHandler.connectionManager not wired — dropping")
            return false
        }

        guard let target = connectionManager.discoveredPeers.first else {
            presentNoPeerAlert()
            return false
        }

        confirmAndSend(urls: urls, target: target, connectionManager: connectionManager)
        return true
    }

    @discardableResult
    static func handle(urls: [URL], toPeerID peerID: String) -> Bool {
        guard !urls.isEmpty else { return false }
        logger.info("Drop received (peer hint: \(peerID.prefix(8), privacy: .public)…): \(urls.map(\.lastPathComponent).joined(separator: ", "), privacy: .public)")

        guard let connectionManager else {
            logger.error("MacDropHandler.connectionManager not wired — dropping")
            return false
        }

        guard let target = connectionManager.discoveredPeers.first(where: { $0.id == peerID }) else {
            logger.error("Target peer \(peerID.prefix(8), privacy: .public) not in discoveredPeers")
            return false
        }

        confirmAndSend(urls: urls, target: target, connectionManager: connectionManager)
        return true
    }

    // MARK: - Private

    private static func presentNoPeerAlert() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString(
            "Connect to a device first",
            comment: "Drop-target alert when no peer is available"
        )
        alert.informativeText = NSLocalizedString(
            "Open PeerDrop and pair with a nearby iPhone or iPad before dropping files.",
            comment: "Drop-target instructional text when no peer is available"
        )
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        alert.runModal()
    }

    private static func confirmAndSend(
        urls: [URL],
        target: DiscoveredPeer,
        connectionManager: ConnectionManager
    ) {
        let alert = NSAlert()
        let names = urls.map(\.lastPathComponent).joined(separator: ", ")
        alert.messageText = String(
            format: NSLocalizedString(
                "Send %d file(s) to %@?",
                comment: "Drop confirmation; %d is file count, %@ is peer display name"
            ),
            urls.count, target.displayName
        )
        alert.informativeText = names
        alert.addButton(withTitle: NSLocalizedString("Send", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            logger.info("User cancelled drop send")
            return
        }

        Task { @MainActor in
            await processAndSend(urls: urls, target: target, connectionManager: connectionManager)
        }
    }

    private static func processAndSend(
        urls: [URL],
        target: DiscoveredPeer,
        connectionManager: ConnectionManager
    ) async {
        connectionManager.showTransferProgress = true
        do {
            // Zip any directories and gather URLs to send. Matches the iOS
            // FilePickerView pattern (PeerDrop/UI/Transfer/FilePickerView.swift).
            var processedURLs: [URL] = []
            var directoryFlags: [URL: Bool] = [:]
            for url in urls {
                let isScoped = url.startAccessingSecurityScopedResource()
                defer {
                    if isScoped { url.stopAccessingSecurityScopedResource() }
                }
                if url.hasDirectoryPath {
                    let zipped = try await url.zipDirectory()
                    processedURLs.append(zipped)
                    directoryFlags[zipped] = true
                } else {
                    processedURLs.append(url)
                    directoryFlags[url] = false
                }
            }

            try await connectionManager.fileTransfer?.sendFiles(
                at: processedURLs,
                to: target.id,
                directoryFlags: directoryFlags
            )
            logger.info("Drop send completed: \(processedURLs.count, privacy: .public) files to \(target.id.prefix(8), privacy: .public)…")
        } catch {
            logger.error("Drop send failed: \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Send failed", comment: "Drop send failure alert title")
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
            alert.runModal()
        }
        connectionManager.showTransferProgress = false
    }
}
#endif
