import SwiftUI
import PeerDropNotes

/// One inbox/sent row: unread dot, sender (or recipient) line, preview, relative time.
struct NoteRowView: View {
    let record: NoteRecord

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(record.isUnread ? Color.accentColor : Color.clear)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
                .accessibilityLabel(record.isUnread ? Text("Unread") : Text(""))
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(headline).font(.subheadline.weight(record.isUnread ? .semibold : .regular)).lineLimit(1)
                    Spacer()
                    Text(record.sentAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                }
                Text(record.text ?? String(localized: "This note could not be decrypted."))
                    .font(.body).foregroundStyle(record.isUndecryptable ? .secondary : .primary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private var headline: String {
        if record.direction == .outbound {
            return String(format: String(localized: "Sent to %@"), NoteRowView.display(record.recipientAccountId ?? ""))
        }
        switch record.sender {
        case .anonymous: return String(localized: "Anonymous")
        case .verified(let id, let nick): return nick.map { "\($0) · \(NoteRowView.display(id))" } ?? NoteRowView.display(id)
        case .unverified: return String(localized: "Unverified sender")
        }
    }

    static func display(_ raw: String) -> String { raw.count == 8 ? raw.prefix(4) + "-" + raw.suffix(4) : raw }
}
