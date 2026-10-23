import SwiftUI

/// Stable colour selection for `PeerAvatar`. `String.hashValue` is randomised per process,
/// so the index comes from FNV-1a over the name's unicode scalars instead.
/// Process-independent hashing (Swift's `hashValue` is randomised per launch).
enum StableHash {
    /// FNV-1a, 32-bit, over the given values (each truncated to 32 bits).
    static func fnv1a32<S: Sequence>(_ values: S) -> UInt32 where S.Element: BinaryInteger {
        var hash: UInt32 = 0x811C9DC5
        for v in values {
            hash ^= UInt32(truncatingIfNeeded: v)
            hash = hash &* 0x01000193
        }
        return hash
    }
}

enum PeerAvatarPalette {
    static func index(for name: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return Int(StableHash.fnv1a32(name.unicodeScalars.map(\.value)) % UInt32(count))
    }

    /// Warm, earthy colours for the paper chat; white initials >= 4.5:1 on each.
    /// terracotta, ochre brown, sage, dusty rose, dusty blue, plum brown.
    static let paperHex: [UInt32] = [0xA8563A, 0x8A6420, 0x5C7A55, 0xA05266, 0x4F6D8C, 0x76506A]

    static let paper: [Color] = paperHex.map {
        Color(red: Double(($0 >> 16) & 0xFF) / 255, green: Double(($0 >> 8) & 0xFF) / 255, blue: Double($0 & 0xFF) / 255)
    }

    static let standard: [Color] = [.blue, .purple, .orange, .green, .pink, .teal]
}

struct PeerAvatar: View {
    let name: String
    static let defaultSize: CGFloat = 40
    var size: CGFloat = PeerAvatar.defaultSize
    var palette: [Color] = PeerAvatarPalette.standard

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
        palette[PeerAvatarPalette.index(for: name, count: palette.count)]
    }
}
