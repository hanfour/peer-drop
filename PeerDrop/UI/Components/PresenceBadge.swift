import SwiftUI
import PeerDropCore

extension PeerPresence {
    /// VoiceOver text; state is never conveyed by colour alone.
    /// Never claims notes can be sent: use `accessibilityLabel(notesReachable:)` when the binding is known.
    var accessibilityLabel: String { accessibilityLabel(notesReachable: false) }

    /// `notesReachable` = the friend has a VERIFIED notes binding, i.e. the thread accepts queued notes.
    func accessibilityLabel(notesReachable: Bool) -> String {
        switch self {
        case .online: return String(localized: "Online")
        case .nearby: return String(localized: "Nearby, not connected")
        case .connecting: return String(localized: "Connecting, not online yet")
        case .offline: return notesReachable ? String(localized: "Offline, you can send notes") : String(localized: "Offline")
        }
    }
}

/// Bottom-trailing status badge: filled dot (online), hollow ring (nearby), dashed ring
/// (connecting across networks), envelope square (offline + notes reachable), grey crescent
/// (offline otherwise).
struct PresenceBadge: View, PaperThemed {
    @Environment(\.paperMode) var paperMode
    let presence: PeerPresence
    let avatarSize: CGFloat
    /// Offline only: true = verified binding (envelope), false = neutral crescent.
    var notesReachable: Bool = false

    enum OfflineKind: Equatable { case notes, neutral }
    static func offlineKind(notesReachable: Bool) -> OfflineKind { notesReachable ? .notes : .neutral }

    /// One shape per state, so state is never conveyed by colour alone.
    enum Shape: Equatable, Hashable { case dot, ring, dashedRing, envelope, crescent }
    static func shape(for presence: PeerPresence, notesReachable: Bool) -> Shape {
        switch presence {
        case .online: return .dot
        case .nearby: return .ring
        case .connecting: return .dashedRing
        case .offline: return offlineKind(notesReachable: notesReachable) == .notes ? .envelope : .crescent
        }
    }

    static func diameter(forAvatarSize size: CGFloat) -> CGFloat { max(12, size * 0.36) }
    private var diameter: CGFloat { Self.diameter(forAvatarSize: avatarSize) }
    private var ringColor: Color { paper(.background) }
    /// Dark glyph on the amber badge in both appearances (noteText is light in dark mode).
    private static let darkGlyph = Color(red: 0x1F / 255, green: 0x16 / 255, blue: 0x10 / 255)

    var body: some View {
        Group {
            switch presence {
            case .online:
                Circle().fill(PaperTheme.color(.online))
            case .nearby:
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().strokeBorder(PaperTheme.color(.highlight), lineWidth: max(2, diameter * 0.2)))
            case .connecting:
                // Dashed grey ring: "on the way", distinct from the solid nearby ring.
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().strokeBorder(Color.gray, style: StrokeStyle(
                        lineWidth: max(2, diameter * 0.2), dash: [max(1.5, diameter * 0.18)])))
            case .offline:
                switch Self.offlineKind(notesReachable: notesReachable) {
                case .notes:
                    RoundedRectangle(cornerRadius: diameter * 0.25, style: .continuous)
                        .fill(PaperTheme.color(.noteBadge))
                        .overlay(
                            Image(systemName: "envelope.fill")
                                .font(.system(size: diameter * 0.6))
                                .foregroundStyle(Self.darkGlyph)
                        )
                case .neutral:
                    // Crescent: a shape no other state uses (dot / ring / envelope square), grey, never colour-only.
                    Image(systemName: "moon.fill")
                        .font(.system(size: diameter * 0.85))
                        .foregroundStyle(Color.gray)
                }
            }
        }
        .frame(width: diameter, height: diameter)
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: presence == .offline && notesReachable ? diameter * 0.25 + 2 : (diameter + 4) / 2, style: .continuous)
                .fill(ringColor)
        )
        .accessibilityHidden(true)
    }
}
