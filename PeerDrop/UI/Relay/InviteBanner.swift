import SwiftUI

struct InviteBanner: View {
    let invite: RelayInvite
    var canAccept: Bool = true
    let onAccept: () -> Void
    let onDecline: () -> Void

    @ScaledMetric private var rowSpacing: CGFloat = 12
    @ScaledMetric private var hPadding: CGFloat = 14
    @ScaledMetric private var vPadding: CGFloat = 10
    @ScaledMetric private var outerHPadding: CGFloat = 10
    @ScaledMetric private var declineHPadding: CGFloat = 10
    @ScaledMetric private var declineVPadding: CGFloat = 6
    @ScaledMetric private var acceptHPadding: CGFloat = 12
    @ScaledMetric private var acceptVPadding: CGFloat = 6
    @ScaledMetric private var progressHPadding: CGFloat = 8

    var body: some View {
        HStack(spacing: rowSpacing) {
            Image(systemName: "person.wave.2.fill")
                .font(.title2)
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text(invite.senderName)
                    .font(.subheadline).bold()
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Text(String(localized: "wants to connect"))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            Button(action: onDecline) {
                Text(String(localized: "Decline"))
                    .font(.caption).bold()
                    .padding(.horizontal, declineHPadding).padding(.vertical, declineVPadding)
                    .background(.white.opacity(0.2), in: Capsule())
                    .foregroundStyle(.white)
            }
            if canAccept {
                Button(action: onAccept) {
                    Text(String(localized: "Accept"))
                        .font(.caption).bold()
                        .padding(.horizontal, acceptHPadding).padding(.vertical, acceptVPadding)
                        .background(.white, in: Capsule())
                        .foregroundStyle(.blue)
                }
            } else {
                ProgressView()
                    .tint(.white)
                    .padding(.horizontal, progressHPadding)
            }
        }
        .padding(.horizontal, hPadding)
        .padding(.vertical, vPadding)
        .background(
            LinearGradient(colors: [.blue, .indigo], startPoint: .leading, endPoint: .trailing),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .padding(.horizontal, outerHPadding)
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
    }
}
