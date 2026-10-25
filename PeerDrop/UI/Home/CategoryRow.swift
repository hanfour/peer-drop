import SwiftUI
import PeerDropCore

/// Navigation value for pushing a category's detail page from Home.
struct CategoryRoute: Hashable {
    let id: String
}

/// One row of Home's 分類 section: folder glyph, name, member count, a bell-slash when the
/// category's notifications are off, a presence glyph (Project F2: eye-slash = shown as offline,
/// moon = inside its offline schedule now, clock = scheduled but online now), and a chevron
/// (the NavigationLink draws it on iOS).
struct CategoryRow: View, PaperThemed {
    @Environment(\.paperMode) var paperMode
    let name: String
    let count: Int
    let notificationsEnabled: Bool
    var presence: CategoryPresence = .online
    /// Whether the category hides us right now (`.offline`, or inside its schedule window).
    var hiddenNow: Bool = false
    /// The Mac row is a plain button, so it draws its own chevron.
    var showsChevron = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.title3)
                .foregroundStyle(.white)
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)   // the tile is a fixed 44 pt, like an avatar
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: PeerAvatarShape.cornerRadius(forSize: 44), style: .continuous)
                    .fill(paper(.brand)))
                .accessibilityHidden(true)
            HStack(spacing: 6) {
                Text(verbatim: name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(paper(.incomingText))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(verbatim: "\(count)")
                    .font(.body)
                    .foregroundStyle(paper(.datePillText))
                if !notificationsEnabled {
                    Image(systemName: "bell.slash")
                        .font(.footnote)
                        .foregroundStyle(paper(.datePillText))
                }
                if let glyph = CategoryRowAccessibility.presenceGlyph(presence: presence, hiddenNow: hiddenNow) {
                    Image(systemName: glyph)
                        .font(.footnote)
                        .foregroundStyle(paper(.datePillText))
                        .accessibilityIdentifier("category-row-presence")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(paper(.datePillText))
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: CategoryRowAccessibility.label(name: name, count: count,
                                                                          notificationsEnabled: notificationsEnabled,
                                                                          presence: presence, hiddenNow: hiddenNow)))
        .accessibilityAddTraits(.isButton)
    }
}

enum CategoryRowAccessibility {
    static func label(name: String, count: Int, notificationsEnabled: Bool,
                      presence: CategoryPresence = .online, hiddenNow: Bool = false) -> String {
        var parts = [name, String(localized: "\(count) friends")]
        if !notificationsEnabled { parts.append(String(localized: "Notifications off")) }
        switch presence {
        case .online: break
        case .offline: parts.append(String(localized: "Shown as offline"))
        case .scheduled:
            parts.append(hiddenNow ? String(localized: "Offline now (scheduled)") : String(localized: "Offline on a schedule"))
        }
        return parts.joined(separator: ", ")
    }

    /// SF Symbol for the row's presence state; nil when the category shows us online.
    static func presenceGlyph(presence: CategoryPresence, hiddenNow: Bool) -> String? {
        switch presence {
        case .online: return nil
        case .offline: return "eye.slash"
        case .scheduled: return hiddenNow ? "moon.zzz" : "clock"
        }
    }
}
