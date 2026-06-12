import SwiftUI
import AppKit
import PeerDropCore
import os

private let logger = Logger(subsystem: "com.hanfour.peerdrop.mac", category: "Commands")

/// Provides command-bar access to ConnectionManager for menu items
/// declared in `PeerDropCommands`. Static-weak pattern matches
/// MacDropHandler / MacDeepLinkHandler — wired in
/// PeerDropMacApp.onAppear.
@MainActor
enum MacCommandHandler {
    static weak var connectionManager: ConnectionManager?
}

struct PeerDropCommands: Commands {
    var body: some Commands {
        // File menu — Round 9 audit fix: previously had 3 stub buttons
        // (New Transfer / Open Inbox / Import Files) that just logged.
        // App Store reviewers test menu items; visible-but-inert items
        // are a Guideline 2.1 reject risk. Now only Import Files… ships
        // — wired to NSOpenPanel + MacDropHandler.
        CommandGroup(replacing: .newItem) {
            Button("Import Files…") {
                presentImportFilesPanel()
            }
            .keyboardShortcut("o")
        }

        // View menu — Toggle Menu Bar Item.
        CommandGroup(after: .sidebar) {
            Button("Toggle Menu Bar Item") {
                if let delegate = NSApp.delegate as? MacAppDelegate {
                    delegate.menuBarVisible.toggle()
                }
            }
        }

        // Peer menu — Round 9 audit fix: Trust Current Peer and Show
        // Pairing SAS… were stubs requiring complex sheet wiring; cut
        // for v6.0 (pairing happens via Relay tab). Refresh Discovery
        // is now wired to ConnectionManager.restartDiscovery via the
        // MacCommandHandler static.
        CommandMenu("Peer") {
            Button("Refresh Discovery") {
                MacCommandHandler.connectionManager?.restartDiscovery()
            }
            .keyboardShortcut("r")
        }

        // Window menu additions — Round 9 audit fix: Inbox was a stub.
        // Only the working "Chat" focus action survives.
        CommandGroup(before: .windowList) {
            Button("Chat") {
                if let chatWindow = NSApp.windows.first(where: {
                    $0.identifier?.rawValue.hasPrefix("chat") == true
                }) {
                    chatWindow.makeKeyAndOrderFront(nil)
                } else {
                    logger.info("Window > Chat: no chat window open")
                }
            }
            .keyboardShortcut("1")
        }

        // Sidebar section jumps (⌘⌥{1-4}).
        CommandGroup(after: .windowList) {
            Button("Nearby")  { postJump(.nearby)  }
                .keyboardShortcut("1", modifiers: [.command, .option])
            Button("Trusted") { postJump(.trusted) }
                .keyboardShortcut("2", modifiers: [.command, .option])
            Button("Relay")   { postJump(.relay)   }
                .keyboardShortcut("3", modifiers: [.command, .option])
            Button("Pet")     { postJump(.pet)     }
                .keyboardShortcut("4", modifiers: [.command, .option])
        }

        // Help menu.
        CommandGroup(replacing: .help) {
            Button("PeerDrop Help") {
                if let url = URL(string: "https://github.com/hanfour/peer-drop#readme") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("Send Feedback") {
                if let url = URL(string: "mailto:hanfourhuang@gmail.com?subject=PeerDrop%20Feedback") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    // MARK: - File > Import Files…

    @MainActor
    private func presentImportFilesPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = NSLocalizedString(
            "Choose files to send.",
            comment: "NSOpenPanel message for File > Import Files…"
        )
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        MacDropHandler.handle(urls: panel.urls)
    }
}

private func postJump(_ section: MacSidebarSection) {
    NotificationCenter.default.post(name: .macSidebarJump, object: section)
}
