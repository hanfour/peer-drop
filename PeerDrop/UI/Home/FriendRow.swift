import SwiftUI
import PeerDropCore
import PeerDropTransport

/// One row of the Home list: avatar with presence badge, single-line name, subtitle,
/// and an optional filled "Connect" pill for nearby friends.
struct FriendRow: View, PaperThemed {
    @Environment(\.paperMode) var paperMode
    let record: DeviceRecord
    let presence: PeerPresence
    var isConnecting: Bool = false
    var onConnect: (() -> Void)? = nil
    /// Live connection of a connected friend; shows the encryption status chip.
    var connection: PeerConnection? = nil

    private var subtitle: String {
        FriendSubtitle.text(presence: presence, lastConnected: record.lastConnected,
                            connectionCount: record.connectionCount, source: record.sourceType,
                            isConnecting: isConnecting)
    }

    var body: some View {
        HStack(spacing: 12) {
            PeerAvatar(name: record.displayName, size: 44, presence: presence)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(record.displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(paper(.incomingText))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(paper(.datePillText))
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(record.displayName), \(presence.accessibilityLabel), \(subtitle)"))

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
                .accessibilityHint(Text(record.displayName))
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }
}
