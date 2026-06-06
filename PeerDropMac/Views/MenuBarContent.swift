import SwiftUI
import PeerDropCore
import PeerDropTransport

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
///   * `connectionManager.petGenome` does not exist; PetEngine is a
///     separate @StateObject that Task 9 will wire into PeerDropMacApp
///     and route here. For now we reserve a 60×60 sprite slot so the
///     popover layout doesn't shift when Pet arrives.
struct MenuBarContent: View {
    @EnvironmentObject var connectionManager: ConnectionManager

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

    // MARK: - Pet sprite slot (Task 9 wires PetEngine renderedImage here)

    private var petSpriteSlot: some View {
        HStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.1))
                .frame(width: 60, height: 60)
                .overlay(
                    Image(systemName: "pawprint")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                )
            Spacer()
            Text("Pet (Task 9)")
                .font(.caption2)
                .foregroundStyle(.secondary)
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

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.circle")
                .foregroundStyle(.tint)
            Text(peer.displayName)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            // Send button stub — Task 10 (drag-and-drop) will wire this to
            // a peer-targeted file picker / drop-accept sheet.
            Button {
                // TODO Task 10: openWindow / sheet to file picker for this peer
            } label: {
                Image(systemName: "paperplane")
            }
            .buttonStyle(.borderless)
            .help("Send to \(peer.displayName)")
        }
        .contentShape(Rectangle())
    }
}
