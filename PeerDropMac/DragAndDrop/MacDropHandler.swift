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

        // Round 7 audit fix: pick a CONNECTED peer, not just any discovered
        // peer. `discoveredPeers` includes Bonjour-visible devices that may
        // not be paired or connected — sending to them would either fail
        // silently (no active session) or, worse, leak file metadata to an
        // unverified peer. Prefer the focused connection; fall back to any
        // discovered peer with an active session.
        guard let targetID = pickConnectedTarget(connectionManager),
              let displayName = displayName(for: targetID, in: connectionManager) else {
            presentNoPeerAlert()
            return false
        }

        confirmAndSend(
            urls: urls,
            targetID: targetID,
            displayName: displayName,
            connectionManager: connectionManager
        )
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

        // Round 7 audit fix: verify the hinted peer is actually connected
        // before opening the confirmation dialog. The peer-row drop site
        // can fire on a discovered-but-not-connected peer (the row is
        // visible just from Bonjour discovery).
        guard connectionManager.isConnected(to: peerID),
              let displayName = displayName(for: peerID, in: connectionManager) else {
            logger.error("Target peer \(peerID.prefix(8), privacy: .public) is not connected")
            presentNotConnectedAlert()
            return false
        }

        confirmAndSend(
            urls: urls,
            targetID: peerID,
            displayName: displayName,
            connectionManager: connectionManager
        )
        return true
    }

    // MARK: - Target selection

    /// Pick a peer that's both connected and ready to receive files. The
    /// focused connection is the primary candidate; otherwise pick any
    /// connected peer that's also in `discoveredPeers` (the AND filter
    /// excludes stale entries left over from a recent disconnect).
    private static func pickConnectedTarget(_ connectionManager: ConnectionManager) -> String? {
        if let focused = connectionManager.focusedPeerID,
           connectionManager.isConnected(to: focused) {
            return focused
        }
        return connectionManager.discoveredPeers.first {
            connectionManager.isConnected(to: $0.id)
        }?.id
    }

    private static func displayName(for peerID: String, in connectionManager: ConnectionManager) -> String? {
        if let identity = connectionManager.connection(for: peerID)?.peerIdentity {
            return identity.displayName
        }
        if let discovered = connectionManager.discoveredPeers.first(where: { $0.id == peerID }) {
            return discovered.displayName
        }
        return nil
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

    private static func presentNotConnectedAlert() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString(
            "This device isn't connected",
            comment: "Drop-target alert when the hinted peer is discovered but not connected"
        )
        alert.informativeText = NSLocalizedString(
            "Open the chat with this device first to send files.",
            comment: "Drop-target instructional text when peer is not connected"
        )
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        alert.runModal()
    }

    private static func confirmAndSend(
        urls: [URL],
        targetID: String,
        displayName: String,
        connectionManager: ConnectionManager
    ) {
        let alert = NSAlert()
        let names = urls.map(\.lastPathComponent).joined(separator: ", ")
        alert.messageText = String(
            format: NSLocalizedString(
                "Send %d file(s) to %@?",
                comment: "Drop confirmation; %d is file count, %@ is peer display name"
            ),
            urls.count, displayName
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
            await processAndSend(
                urls: urls,
                targetID: targetID,
                connectionManager: connectionManager
            )
        }
    }

    private static func processAndSend(
        urls: [URL],
        targetID: String,
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
                to: targetID,
                directoryFlags: directoryFlags
            )
            logger.info("Drop send completed: \(processedURLs.count, privacy: .public) files to \(targetID.prefix(8), privacy: .public)…")
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
