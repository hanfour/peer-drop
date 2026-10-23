import SwiftUI

/// Friendly placeholder shown in a chat that has no messages yet.
/// Centred, rounded type, warm colour; deliberately static (no animation).
struct EmptyChatView: View {
    let message: String

    var body: some View {
        Text(verbatim: message)
            .font(.system(.body, design: .rounded))
            .foregroundStyle(PaperTheme.color(.datePillText))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
