import Foundation
import os

/// Shared drop logic for Dock/main-window/menu-bar drop sites.
///
/// Task 10 ships the structural scaffolding: log the drop + the suggested
/// peer (if any). The actual "raise a peer-selection confirmation sheet +
/// send file" flow depends on a future ConnectionManager API addition
/// (`handleIncomingFiles(urls:suggestedPeerID:)`) and Task 6b's
/// FilePickerView refactor. Until then, drops are logged for debugging.
///
/// App Review compliance: drops MUST NEVER send silently. The future
/// implementation MUST present a confirmation sheet before any data leaves
/// the device.
@MainActor
enum MacDropHandler {
    private static let logger = Logger(subsystem: "com.hanfour.peerdrop.mac", category: "MacDropHandler")

    /// Process a generic drop (Dock icon or main window — no specific peer).
    /// Returns true to indicate the drop site accepts the URLs.
    @discardableResult
    static func handle(urls: [URL]) -> Bool {
        logger.info("Drop received (no peer hint): \(urls.map(\.lastPathComponent).joined(separator: ", "))")
        // TODO post-M2: present a peer-selection sheet, then dispatch
        // to ConnectionManager.handleIncomingFiles(urls:suggestedPeerID:)
        // once that API exists.
        return true
    }

    /// Process a drop targeted at a specific peer (menu-bar peer-row drop).
    /// Still requires a confirmation sheet — peer ID is just a default
    /// suggestion in the future sheet UI.
    @discardableResult
    static func handle(urls: [URL], toPeerID peerID: String) -> Bool {
        logger.info("Drop received (peer hint: \(peerID.prefix(8))…): \(urls.map(\.lastPathComponent).joined(separator: ", "))")
        // TODO post-M2: present a confirmation sheet pre-targeted at peerID,
        // then dispatch via ConnectionManager.handleIncomingFiles(urls:suggestedPeerID:).
        return true
    }
}
