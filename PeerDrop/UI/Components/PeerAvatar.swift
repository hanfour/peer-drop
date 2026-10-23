import SwiftUI

struct PeerAvatar: View {
    let name: String
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            Circle()
                .fill(color)
                .frame(width: size, height: size)

            Text(initials)
                .font(.system(size: size * 0.35, weight: .semibold))
                .foregroundStyle(.white)
        }
        .accessibilityLabel("Avatar for \(name)")
        .accessibilityHidden(true)
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
