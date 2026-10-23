import SwiftUI

/// Centered day separator shown before the first message of each day.
struct ChatDatePill: View {
    let date: Date

    var body: some View {
        Text(date.formatted(.dateTime.month().day().weekday()))
            .font(.system(.caption, design: .rounded))
            .foregroundStyle(PaperTheme.color(.datePillText))
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Capsule().fill(PaperTheme.color(.datePillFill)))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
    }
}
