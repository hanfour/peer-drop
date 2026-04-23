import SwiftUI

struct GuidanceCard: View {
    @EnvironmentObject var context: ConnectionContext
    @EnvironmentObject var connectionManager: ConnectionManager
    let trigger: Trigger
    let onMoreOptions: () -> Void
    let onDismiss: (() -> Void)?

    enum Trigger { case emptyState; case failure(reason: String) }

    var body: some View {
        card(for: context.primaryRecommendation)
            .padding(.horizontal, 16).padding(.vertical, 8)
    }

    @ViewBuilder
    private func card(for rec: ConnectionRecommendation) -> some View {
        switch rec {
        case .useInviteKnownDevice(let device):
            primaryCard(icon: "person.crop.circle.fill.badge.checkmark",
                        title: String(localized: "Connect again with \(device.displayName)"),
                        primaryLabel: String(localized: "Invite"),
                        primaryAction: { connectionManager.shouldShowRelayConnect = true },
                        subtitle: device.relativeLastConnected)
        case .useTailnet:
            primaryCard(icon: "network.badge.shield.half.filled",
                        title: String(localized: "Found a Tailscale device nearby"),
                        primaryLabel: String(localized: "Connect"),
                        primaryAction: { connectionManager.shouldShowRelayConnect = true },
                        subtitle: String(localized: "Via your tailnet"))
        case .useRelayCode:
            primaryCard(icon: "antenna.radiowaves.left.and.right",
                        title: String(localized: "Create a Relay room"),
                        primaryLabel: String(localized: "Create Room"),
                        primaryAction: { connectionManager.shouldShowRelayConnect = true })
        case .configureTailscale:
            primaryCard(icon: "network.slash",
                        title: String(localized: "Connection keeps failing?"),
                        primaryLabel: String(localized: "Try Tailscale"),
                        primaryAction: openTailscaleAppStore,
                        subtitle: String(localized: "A free VPN that makes cross-network connect feel like same-network"))
        case .useQRScan, .waitForDiscovery:
            EmptyView()
        }
    }

    private func primaryCard(icon: String, title: String, primaryLabel: String,
                             primaryAction: @escaping () -> Void, subtitle: String? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold()).foregroundStyle(.white)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.85)) }
            }
            Spacer()
            Button(action: primaryAction) {
                Text(primaryLabel).font(.caption.bold())
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.white, in: Capsule()).foregroundStyle(.blue)
            }
            Button(action: onMoreOptions) {
                Image(systemName: "ellipsis.circle").font(.caption).foregroundStyle(.white.opacity(0.9))
            }
            if let onDismiss {
                Button(action: onDismiss) { Image(systemName: "xmark").font(.caption).foregroundStyle(.white.opacity(0.9)) }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(LinearGradient(colors: [.blue, .indigo], startPoint: .leading, endPoint: .trailing),
                    in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
    }

    private func openTailscaleAppStore() {
        guard let url = URL(string: "https://apps.apple.com/app/tailscale/id1470499037") else { return }
        UIApplication.shared.open(url)
    }
}
