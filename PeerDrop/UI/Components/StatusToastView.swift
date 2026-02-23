import SwiftUI

struct StatusToastView: View {
    let message: String
    let icon: String
    let iconColor: Color

    init(_ message: String, icon: String = "info.circle.fill", iconColor: Color = .secondary) {
        self.message = message
        self.icon = icon
        self.iconColor = iconColor
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)

            Text(message)
                .font(.subheadline)
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Color(.label).opacity(0.12), radius: 8, y: 4)
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
    }
}
