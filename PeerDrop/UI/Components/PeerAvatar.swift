import SwiftUI

struct PeerAvatar: View {
    let name: String

    var body: some View {
        ZStack {
            Circle()
                .fill(color)
                .frame(width: 40, height: 40)

            Text(initials)
                .font(.system(.callout, weight: .semibold))
                .foregroundStyle(.white)
        }
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
