import SwiftUI
import PeerDropCore
import PeerDropTransport

/// One row of the Home list: avatar with presence badge, single-line name, subtitle,
/// and an optional filled "Connect" pill for nearby friends.
struct FriendRow: View, PaperThemed {
    @Environment(\.paperMode) var paperMode
    let record: DeviceRecord
    /// Resolved display name (live connection name for relay placeholders); falls back to the stored name.
    var name: String? = nil
    let presence: PeerPresence
    /// Verified notes binding: an offline friend can still be sent notes.
    var notesReachable: Bool = false
    var isConnecting: Bool = false
    var onConnect: (() -> Void)? = nil
    /// Live connection of a connected friend; shows the encryption status chip.
    var connection: PeerConnection? = nil
    /// Category the friend sits in; shown as a caption on search results (nil = no caption).
    var categoryName: String? = nil

    private var shownName: String { name ?? record.displayName }

    private var subtitle: String {
        FriendSubtitle.text(presence: presence, lastConnected: record.lastConnected,
                            connectionCount: record.connectionCount, source: record.sourceType,
                            isConnecting: isConnecting)
    }

    private var accessibilityText: String {
        let base = FriendRowAccessibility.label(name: shownName, presenceLabel: presence.accessibilityLabel(notesReachable: notesReachable),
                                                subtitle: subtitle, isConnecting: isConnecting && presence != .online)
        guard let categoryName else { return base }
        return base + ", " + String(format: String(localized: "Category: %@"), categoryName)
    }

    var body: some View {
        HStack(spacing: 12) {
            PeerAvatar(name: shownName, size: 44, presence: presence, notesReachable: notesReachable)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(shownName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(paper(.incomingText))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(paper(.datePillText))
                    .lineLimit(2)
                if let categoryName {
                    HStack(spacing: 3) {
                        Image(systemName: "folder")
                        Text(verbatim: categoryName).lineLimit(1)
                    }
                    .font(.caption2)
                    .foregroundStyle(paper(.datePillText))
                    .accessibilityIdentifier("friend-row-category")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: accessibilityText))

            if let connection {
                SecureChannelIndicator(peerConn: connection)
            }

            if HomeListLogic.showsConnectPill(presence: presence, isConnecting: isConnecting), let onConnect {
                Button(action: onConnect) {
                    Text("Connect")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(paper(.brand)))
                }
                .buttonStyle(.borderless)
                .fixedSize()
                .accessibilityLabel(Text("Connect"))
                .accessibilityHint(Text(shownName))
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }
}

/// VoiceOver text of a Home row. While connecting, the presence label ("Nearby, not connected")
/// would contradict the subtitle ("Connecting..."), so only the subtitle is spoken.
enum FriendRowAccessibility {
    static func label(name: String, presenceLabel: String, subtitle: String, isConnecting: Bool) -> String {
        isConnecting ? "\(name), \(subtitle)" : "\(name), \(presenceLabel), \(subtitle)"
    }
}
