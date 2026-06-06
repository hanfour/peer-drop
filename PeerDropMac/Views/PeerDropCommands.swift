import SwiftUI
import AppKit
import os

private let logger = Logger(subsystem: "com.hanfour.peerdrop.mac", category: "Commands")

struct PeerDropCommands: Commands {
    var body: some Commands {
        // File menu — replaces the default "New Document" + "Open Recent" with PeerDrop-specific actions
        CommandGroup(replacing: .newItem) {
            Button("New Transfer…") {
                // TODO post-M2: openWindow / present a peer-picker sheet
                logger.info("File > New Transfer (TODO post-M2)")
            }
            .keyboardShortcut("n")

            Button("Open Inbox") {
                // TODO post-M2: focus inbox window or open it if absent
                logger.info("File > Open Inbox (TODO post-M2)")
            }
            .keyboardShortcut("i")

            Button("Import Files…") {
                // TODO post-M2: present NSOpenPanel, route to MacDropHandler
                logger.info("File > Import Files (TODO post-M2)")
            }
            .keyboardShortcut("o")
        }

        // View menu — add a Toggle Menu Bar Item entry after the native Toggle Sidebar
        CommandGroup(after: .sidebar) {
            Button("Toggle Menu Bar Item") {
                // Read+toggle MacAppDelegate.menuBarVisible
                if let delegate = NSApp.delegate as? MacAppDelegate {
                    delegate.menuBarVisible.toggle()
                }
            }
        }

        // Peer menu — custom top-level command menu
        CommandMenu("Peer") {
            Button("Refresh Discovery") {
                // ConnectionManager exposes `restartDiscovery()` (the audit
                // found `refreshDiscovery` doesn't exist). Wiring requires
                // FocusedSceneValue plumbing — TODO post-M2.
                logger.info("Peer > Refresh Discovery (TODO post-M2 — needs FocusedSceneValue wiring)")
            }
            .keyboardShortcut("r")

            Divider()

            Button("Trust Current Peer") {
                // TODO post-M2
                logger.info("Peer > Trust Current Peer (TODO post-M2)")
            }

            Button("Show Pairing SAS…") {
                // TODO post-M2: present SAS pairing sheet
                logger.info("Peer > Show Pairing SAS (TODO post-M2)")
            }
            .keyboardShortcut("p", modifiers: [.shift, .command])
        }

        // Window menu additions (⌘1 / ⌘2). The chat WindowGroup deliberately
        // omits its own ⌘1 binding so this menu item is the canonical owner
        // of the shortcut (and avoids the SwiftUI undefined-resolution case
        // when two scenes claim the same key).
        CommandGroup(before: .windowList) {
            Button("Chat") {
                // Focus the most-recent chat window if one is open.
                if let chatWindow = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("chat") == true }) {
                    chatWindow.makeKeyAndOrderFront(nil)
                } else {
                    logger.info("Window > Chat: no chat window open (TODO post-M2: open peer picker)")
                }
            }
            .keyboardShortcut("1")

            Button("Inbox") {
                // TODO post-M2: open or focus the Inbox window
                logger.info("Window > Inbox (TODO post-M2)")
            }
            .keyboardShortcut("2")
        }

        // Sidebar section jumps (⌘⌥{1-4}). Posted as a notification so
        // MacContentView (which owns @State sidebar selection) can update.
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

        // Help menu — fully functional
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
}

private func postJump(_ section: MacSidebarSection) {
    NotificationCenter.default.post(name: .macSidebarJump, object: section)
}
