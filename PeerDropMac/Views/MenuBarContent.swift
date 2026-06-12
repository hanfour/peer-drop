import SwiftUI
import PeerDropCore
import PeerDropTransport
import PeerDropPet

/// Contents of the MenuBarExtra popover (~360×500).
///
/// Spec §4 menu bar layout: status header, peers list, in-flight
/// transfers, Pet mini-sprite slot, and Open / Quit row.
///
/// Deviation notes (vs. plan):
///   * The plan referenced `connectionManager.aggregateState`. The actual
///     ConnectionManager exposes `state: ConnectionState` — used here.
///   * `connectionManager.activeTransfers` does not exist; only
///     `transferProgress: Double`. We render a static "No active
///     transfers" placeholder. A real transfers list is a post-M2 pass.
///   * Task 9 wires the Pet sprite: PetEngine is a separate
///     @StateObject in PeerDropMacApp (the plan's
///     `connectionManager.currentPetSprite` doesn't exist). The
///     mini-sprite consumes `petEngine.renderedImage` via the shared
///     `PetSpriteView(size:)` component.
struct MenuBarContent: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @EnvironmentObject var petEngine: PetEngine

    var body: some View {
        VStack(spacing: 0) {
            statusHeader

            Divider()

            if connectionManager.discoveredPeers.isEmpty {
                emptyPeersPlaceholder
            } else {
                peersList
            }

            Divider()

            transfersPlaceholder

            Divider()

            petSpriteSlot

            Divider()

            openQuitRow
        }
        .frame(width: 360, height: 500)
    }

    // MARK: - Status header

    private var statusHeader: some View {
        HStack {
            MenuBarStatusIcon(state: connectionManager.state)
            Text(statusText)
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var statusText: String {
        switch connectionManager.state {
        case .idle:            return NSLocalizedString("Idle", comment: "")
        case .discovering:     return NSLocalizedString("Discovering…", comment: "")
        case .peerFound:       return NSLocalizedString("Peer found", comment: "")
        case .requesting:      return NSLocalizedString("Requesting…", comment: "")
        case .incomingRequest: return NSLocalizedString("Incoming request", comment: "")
        case .connecting:      return NSLocalizedString("Connecting…", comment: "")
        case .connected:       return NSLocalizedString("Connected", comment: "")
        case .transferring:    return NSLocalizedString("Transferring…", comment: "")
        case .voiceCall:       return NSLocalizedString("In call", comment: "")
        case .disconnected:    return NSLocalizedString("Disconnected", comment: "")
        case .rejected:        return NSLocalizedString("Rejected", comment: "")
        case .failed:          return NSLocalizedString("Failed", comment: "")
        }
    }

    // MARK: - Peers list

    private var emptyPeersPlaceholder: some View {
        VStack(spacing: 4) {
            Image(systemName: "wifi.exclamationmark")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No peers found")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    private var peersList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(connectionManager.discoveredPeers) { peer in
                    MenuBarPeerRow(peer: peer)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .frame(maxHeight: 220)
    }

    // MARK: - Transfers placeholder (real list is a post-M2 pass)

    private var transfersPlaceholder: some View {
        HStack(spacing: 6) {
            Image(systemName: "tray")
                .foregroundStyle(.secondary)
            Text("No active transfers")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    // MARK: - Pet sprite slot (Task 9: live PetEngine sprite at 60pt)

    private var petSpriteSlot: some View {
        HStack(spacing: 12) {
            PetSpriteView(size: 60)
            VStack(alignment: .leading, spacing: 2) {
                if let name = petEngine.pet.name, !name.isEmpty {
                    Text(name)
                        .font(.caption)
                        .lineLimit(1)
                }
                // PetState exposes `level: PetLevel` (plan called it
                // `stage`). `displayName` gives the localised stage label.
                Text(petEngine.pet.level.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    // MARK: - Open / Quit

    private var openQuitRow: some View {
        HStack {
            Button("Open PeerDrop") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows
                    .first(where: { $0.identifier?.rawValue == "PeerDropMain" })?
                    .makeKeyAndOrderFront(nil)
            }
            Spacer()
            Button("Quit") {
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 12)
        .padding(.top, 8)
    }
}

// MARK: - Peer row

private struct MenuBarPeerRow: View {
    let peer: DiscoveredPeer
    @State private var isDropTargeted = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.circle")
                .foregroundStyle(.tint)
            Text(peer.displayName)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            // Round 10 audit fix: previously a stub paperplane button
            // that did nothing. Now opens the per-peer chat window.
            // File-send is reachable via drag-drop onto this row's
            // dropDestination (round 6) + File > Import Files… (⌘O,
            // round 9).
            Button {
                openWindow(id: "chat", value: peer.id)
            } label: {
                Image(systemName: "bubble.left.and.bubble.right")
            }
            .buttonStyle(.borderless)
            .help("Chat with \(peer.displayName)")
        }
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .dropDestination(for: URL.self) { urls, _ in
            MacDropHandler.handle(urls: urls, toPeerID: peer.id)
        } isTargeted: { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isDropTargeted = hovering
            }
        }
    }
}
