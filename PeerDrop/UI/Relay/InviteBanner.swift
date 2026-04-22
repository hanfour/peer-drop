import SwiftUI

struct InviteBanner: View {
    let invite: RelayInvite
    var canAccept: Bool = true
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.wave.2.fill")
                .font(.title2)
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text(invite.senderName)
                    .font(.subheadline).bold()
                    .foregroundStyle(.white)
                Text(String(localized: "wants to connect"))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
            }
            Spacer()
            Button(action: onDecline) {
                Text(String(localized: "Decline"))
                    .font(.caption).bold()
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.white.opacity(0.2), in: Capsule())
                    .foregroundStyle(.white)
            }
            if canAccept {
                Button(action: onAccept) {
                    Text(String(localized: "Accept"))
                        .font(.caption).bold()
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.white, in: Capsule())
                        .foregroundStyle(.blue)
                }
            } else {
                ProgressView()
                    .tint(.white)
                    .padding(.horizontal, 8)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            LinearGradient(colors: [.blue, .indigo], startPoint: .leading, endPoint: .trailing),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .padding(.horizontal, 10)
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
    }
}
