import SwiftUI

struct PeerAvatar: View {
    let name: String
    static let defaultSize: CGFloat = 40
    var size: CGFloat = PeerAvatar.defaultSize

    var body: some View {
        ZStack {
            Circle()
                .fill(color)
                .frame(width: size, height: size)

            Text(initials)
                .font(initialsFont)
                .foregroundStyle(.white)
        }
        .accessibilityLabel("Avatar for \(name)")
        .accessibilityHidden(true)
    }

    /// Default size keeps the original Dynamic-Type-scaling callout font;
    /// other sizes use a size-proportional font.
    private var initialsFont: Font {
        size == Self.defaultSize
            ? .system(.callout, weight: .semibold)
            : .system(size: size * 0.4, weight: .semibold)
    }

    private var initials: String {
        let parts = name.split(separator: " ")
        if parts.count >= 2 {
            return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    private var color: Color {
        let colors: [Color] = [.blue, .purple, .orange, .green, .pink, .teal]
        let hash = abs(name.hashValue)
        return colors[hash % colors.count]
    }
}
