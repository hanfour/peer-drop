import SwiftUI

struct TrustBadgeView: View {
    let trustLevel: TrustLevel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: trustLevel.sfSymbol)
                .font(.caption)
            Text(trustLevel.localizedLabel)
                .font(.caption)
        }
        .foregroundStyle(color)
    }

    private var color: Color {
        switch trustLevel {
        case .verified: return .green
        case .linked: return .blue
        case .unknown: return .orange
        }
    }
}
