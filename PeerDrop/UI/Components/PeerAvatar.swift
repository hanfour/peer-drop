import SwiftUI
import PeerDropCore

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

    /// MSN swatches. Blue is 0076D4 (not 0078D7) so white label reaches 4.5:1, same as the brand token.
    static let swatches: [AvatarSwatch] = [
        AvatarSwatch(fill: 0x0076D4, label: 0xFFFFFF),
        AvatarSwatch(fill: 0x107C41, label: 0xFFFFFF),
        AvatarSwatch(fill: 0xF9A825, label: 0x3A2A05),
        AvatarSwatch(fill: 0xC50F1F, label: 0xFFFFFF),
    ]

    static func swatch(for name: String) -> AvatarSwatch {
        swatches[index(for: name, count: swatches.count)]
    }
}

struct AvatarSwatch: Equatable {
    let fill: UInt32
    let label: UInt32

    var fillColor: Color { Color(hex: fill) }
    var labelColor: Color { Color(hex: label) }
}

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

enum PeerAvatarShape {
    static func cornerRadius(forSize size: CGFloat) -> CGFloat {
        size >= 44 ? 16 : size * 0.36
    }
}

struct PeerAvatar: View {
    let name: String
    static let defaultSize: CGFloat = 40
    var size: CGFloat = PeerAvatar.defaultSize
    /// nil = MSN swatches (white/dark label per swatch). A custom palette uses white initials.
    var palette: [Color]? = nil
    /// nil = no badge.
    var presence: PeerPresence? = nil
    /// Verified notes binding: an offline friend can still be sent notes (envelope badge). Default false.
    var notesReachable: Bool = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: PeerAvatarShape.cornerRadius(forSize: size), style: .continuous)
                .fill(fillColor)
                .frame(width: size, height: size)

            Text(initials)
                .font(initialsFont)
                .foregroundStyle(labelColor)
        }
        .saturation(presence == .offline ? 0.35 : 1)
        .overlay(alignment: .bottomTrailing) {
            if let presence {
                PresenceBadge(presence: presence, avatarSize: size, notesReachable: notesReachable)
                    .offset(x: 2, y: 2)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityText(name: name, presence: presence, notesReachable: notesReachable))
        .accessibilityHidden(Self.isAccessibilityHidden(presence: presence))
    }

    /// Decorative (hidden) unless a presence state needs to be announced.
    static func isAccessibilityHidden(presence: PeerPresence?) -> Bool { presence == nil }

    static func accessibilityText(name: String, presence: PeerPresence?, notesReachable: Bool = false) -> String {
        let base = String(format: String(localized: "Avatar for %@"), name)
        guard let presence else { return base }
        return "\(base), \(presence.accessibilityLabel(notesReachable: notesReachable))"
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

    private var fillColor: Color {
        if let palette, !palette.isEmpty {
            return palette[PeerAvatarPalette.index(for: name, count: palette.count)]
        }
        return PeerAvatarPalette.swatch(for: name).fillColor
    }

    private var labelColor: Color {
        palette?.isEmpty ?? true ? PeerAvatarPalette.swatch(for: name).labelColor : .white
    }
}
