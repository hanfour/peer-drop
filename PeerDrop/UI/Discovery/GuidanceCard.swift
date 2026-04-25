import SwiftUI

struct GuidanceCard: View {
    @EnvironmentObject var context: ConnectionContext
    @EnvironmentObject var connectionManager: ConnectionManager
    let trigger: Trigger
    let onMoreOptions: () -> Void
    let onDismiss: (() -> Void)?

    @ScaledMetric private var rowSpacing: CGFloat = 12
    @ScaledMetric private var hPadding: CGFloat = 14
    @ScaledMetric private var vPadding: CGFloat = 10
    @ScaledMetric private var outerHPadding: CGFloat = 16
    @ScaledMetric private var outerVPadding: CGFloat = 8
    @ScaledMetric private var pillHPadding: CGFloat = 12
    @ScaledMetric private var pillVPadding: CGFloat = 6

    enum Trigger { case emptyState; case failure(reason: String) }

    var body: some View {
        card(for: context.primaryRecommendation)
            .padding(.horizontal, outerHPadding).padding(.vertical, outerVPadding)
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
        HStack(spacing: rowSpacing) {
            Image(systemName: icon).font(.title2).foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold()).foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            Button(action: primaryAction) {
                Text(primaryLabel).font(.caption.bold())
                    .padding(.horizontal, pillHPadding).padding(.vertical, pillVPadding)
                    .background(.white, in: Capsule()).foregroundStyle(.blue)
            }
            Button(action: onMoreOptions) {
                Image(systemName: "ellipsis.circle").font(.caption).foregroundStyle(.white.opacity(0.9))
            }
            if let onDismiss {
                Button(action: onDismiss) { Image(systemName: "xmark").font(.caption).foregroundStyle(.white.opacity(0.9)) }
            }
        }
        .padding(.horizontal, hPadding).padding(.vertical, vPadding)
        .background(LinearGradient(colors: [.blue, .indigo], startPoint: .leading, endPoint: .trailing),
                    in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
    }

    private func openTailscaleAppStore() {
        guard let url = URL(string: "https://apps.apple.com/app/tailscale/id1470499037") else { return }
        UIApplication.shared.open(url)
    }
}
