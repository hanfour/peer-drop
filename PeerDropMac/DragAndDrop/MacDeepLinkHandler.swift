#if canImport(AppKit)
import AppKit
import Foundation
import PeerDropCore
import PeerDropSecurity
import os

/// Routes `peerdrop://` URL-scheme deep links into the same code paths
/// iOS uses (PeerDrop/App/PeerDropApp.swift `handleDeepLink`).
///
/// Round 8 audit fix: MacAppDelegate.application(_:open:) was sending
/// every URL — including peerdrop:// scheme URLs — to MacDropHandler,
/// which treated them as file drops. Result: clicking a
/// `peerdrop://invite/?…` URL on Mac (from iMessage, email, or a
/// QR-code scanner) silently triggered a "Send 1 file to <peer>?"
/// confirmation instead of the invite-accept flow.
///
/// Four supported schemes (mirror of iOS):
///   - `peerdrop://relay/CODE` — preset the relay-join code
///   - `peerdrop://connect/HOST:PORT[/NAME]` — add a manual peer
///   - `peerdrop://invite?mbx=…&fp=…&name=…&exp=…` — show accept
///     confirmation
///   - `peerdrop://smart?ts=…&local=…&relay=…&name=…` — multi-hint
///     connection (TS → local → relay fallback)
@MainActor
enum MacDeepLinkHandler {
    private static let logger = Logger(subsystem: "com.hanfour.peerdrop.mac", category: "MacDeepLinkHandler")

    /// Wired by `PeerDropMacApp.onAppear` (same lifecycle as
    /// MacDropHandler.connectionManager).
    static weak var connectionManager: ConnectionManager?

    @discardableResult
    static func handle(_ url: URL) -> Bool {
        guard url.scheme == "peerdrop" else { return false }
        logger.info("Deep link: \(url.absoluteString, privacy: .public)")

        guard let connectionManager else {
            logger.error("MacDeepLinkHandler.connectionManager not wired — dropping")
            return false
        }

        switch url.host {
        case "relay":
            return handleRelay(url, connectionManager: connectionManager)
        case "connect":
            return handleConnect(url, connectionManager: connectionManager)
        case "smart":
            return handleSmart(url, connectionManager: connectionManager)
        case "invite":
            return handleInvite(url, connectionManager: connectionManager)
        default:
            logger.warning("Unknown peerdrop:// host: \(url.host ?? "<nil>", privacy: .public)")
            return false
        }
    }

    // MARK: - Handlers

    private static func handleRelay(_ url: URL, connectionManager: ConnectionManager) -> Bool {
        guard let code = url.pathComponents.dropFirst().first,
              code.count == 6 else {
            logger.warning("Invalid relay code in peerdrop://relay URL")
            return false
        }
        connectionManager.pendingRelayJoinCode = code.uppercased()
        connectionManager.shouldShowRelayConnect = true
        return true
    }

    private static func handleConnect(_ url: URL, connectionManager: ConnectionManager) -> Bool {
        guard let hostPort = url.pathComponents.dropFirst().first,
              let (host, port) = parseHostPort(hostPort) else {
            logger.warning("Invalid host:port in peerdrop://connect URL")
            return false
        }
        let name = url.pathComponents.count > 2 ? url.pathComponents[2] : nil
        connectionManager.addManualPeer(host: host, port: port, name: name)
        return true
    }

    private static func handleSmart(_ url: URL, connectionManager: ConnectionManager) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            logger.warning("peerdrop://smart URL missing query items")
            return false
        }
        var hostPorts: [String] = []
        var relayCode: String? = nil
        var name: String? = nil
        for item in queryItems {
            switch item.name {
            case "ts", "local":
                if let v = item.value { hostPorts.append(v) }
            case "relay":
                relayCode = item.value
            case "name":
                name = item.value
            default:
                break
            }
        }
        // Try each host:port in order, then fall back to relay if all fail.
        // For v6.0 simplicity, attempt the first host:port and the relay in
        // parallel — same as iOS handleSmartDeepLink.
        for hostPort in hostPorts {
            if let (host, port) = parseHostPort(hostPort) {
                connectionManager.addManualPeer(host: host, port: port, name: name)
            }
        }
        if let code = relayCode, code.count == 6 {
            connectionManager.pendingRelayJoinCode = code.uppercased()
            connectionManager.shouldShowRelayConnect = true
        }
        return true
    }

    private static func handleInvite(_ url: URL, connectionManager: ConnectionManager) -> Bool {
        let invite: InvitePayload
        do {
            invite = try InvitePayload(from: url)
        } catch {
            logger.warning("Invalid peerdrop://invite URL: \(error.localizedDescription, privacy: .public)")
            return false
        }
        guard invite.expiry > Date() else {
            presentAlert(
                title: NSLocalizedString("Invite expired", comment: "Invite-expiry alert title"),
                message: NSLocalizedString(
                    "Ask the sender to share a new invite.",
                    comment: "Invite-expiry alert message"
                )
            )
            return false
        }

        let alert = NSAlert()
        alert.messageText = String(
            format: NSLocalizedString(
                "Accept invite from %@?",
                comment: "Invite-accept alert title; %@ is the sender's display name"
            ),
            invite.displayName
        )
        alert.informativeText = NSLocalizedString(
            "Accepting will pair this Mac with the sender's device so you can share files and chat.",
            comment: "Invite-accept alert body"
        )
        alert.addButton(withTitle: NSLocalizedString("Accept", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Decline", comment: ""))
        guard alert.runModal() == .alertFirstButtonReturn else {
            logger.info("User declined invite from \(invite.displayName, privacy: .public)")
            return false
        }

        Task { @MainActor in
            do {
                try await connectionManager.acceptRemoteInvite(invite)
                logger.info("Invite accepted from \(invite.displayName, privacy: .public)")
            } catch {
                logger.error("acceptRemoteInvite failed: \(error.localizedDescription, privacy: .public)")
                presentAlert(
                    title: NSLocalizedString("Couldn't accept invite", comment: "Accept-failure alert title"),
                    message: error.localizedDescription
                )
            }
        }
        return true
    }

    // MARK: - Private helpers

    private static func parseHostPort(_ s: String) -> (String, UInt16)? {
        let parts = s.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let port = UInt16(parts[1]) else { return nil }
        return (String(parts[0]), port)
    }

    private static func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        alert.runModal()
    }
}
#endif
