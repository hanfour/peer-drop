import SwiftUI
import PeerDropCore

/// One row of the 紙條 list: avatar (presence for friends, group glyph for groups), name,
/// one-line preview, time and an unread badge.
struct ConversationRow: View, PaperThemed {
    @Environment(\.paperMode) var paperMode
    let model: ConversationRowModel
    /// nil for groups (no presence badge).
    let presence: PeerPresence?
    /// Verified notes binding (offline friends only matter).
    var notesReachable: Bool = false

    private var preview: String { ConversationsLogic.preview(model.summary) }

    private var timeText: String {
        guard let d = model.summary.lastActivity else { return "" }
        return ConversationTime.text(for: d)
    }

    var body: some View {
        HStack(spacing: 12) {
            avatar.accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(paper(.incomingText))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(preview)
                    .font(.subheadline)
                    .foregroundStyle(paper(.datePillText))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 4) {
                Text(timeText)
                    .font(.caption)
                    .foregroundStyle(paper(.datePillText))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if model.summary.unread > 0 {
                    Text(model.summary.unread > 99 ? "99+" : "\(model.summary.unread)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .frame(minWidth: 20)
                        .background(Capsule().fill(paper(.brand)))
                }
            }
            .frame(maxWidth: 90, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
    }

    @ViewBuilder
    private var avatar: some View {
        if model.isGroup {
            RoundedRectangle(cornerRadius: PeerAvatarShape.cornerRadius(forSize: 44), style: .continuous)
                .fill(paper(.brand))
                .frame(width: 44, height: 44)
                .overlay(Image(systemName: "person.3.fill").foregroundStyle(.white))
        } else {
            PeerAvatar(name: model.name, size: 44, presence: presence, notesReachable: notesReachable)
        }
    }

    private var accessibilityText: String {
        var parts = [model.name]
        if let presence, !model.isGroup { parts.append(presence.accessibilityLabel(notesReachable: notesReachable)) }
        if model.summary.unread > 0 {
            parts.append(String(format: String(localized: "%lld unread"), model.summary.unread))
        }
        parts.append(preview)
        parts.append(timeText)
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// "14:05" today, otherwise a localized relative day ("Yesterday") or short date.
enum ConversationTime {
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short; return f
    }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .none; f.doesRelativeDateFormatting = true; return f
    }()

    static func text(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        calendar.isDate(date, inSameDayAs: now) ? timeFormatter.string(from: date) : dayFormatter.string(from: date)
    }
}
