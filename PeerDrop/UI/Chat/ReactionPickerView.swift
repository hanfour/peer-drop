import SwiftUI

/// Quick emoji reaction picker.
struct ReactionPickerView: View {
    let onSelect: (String) -> Void
    let onDismiss: () -> Void

    private let emojis = ["👍", "❤️", "😂", "😮", "😢", "🔥"]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(emojis, id: \.self) { emoji in
                Button {
                    onSelect(emoji)
                } label: {
                    Text(emoji)
                        .font(.title2)
                }
                .buttonStyle(ReactionButtonStyle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }
}

private struct ReactionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 1.3 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Displays reactions on a message bubble.
struct ReactionsView: View {
    let reactions: [String: Set<String>]  // emoji -> senderIDs
    let isOutgoing: Bool

    var body: some View {
        if !sortedReactions.isEmpty {
            HStack(spacing: 4) {
                ForEach(sortedReactions, id: \.emoji) { item in
                    HStack(spacing: 2) {
                        Text(item.emoji)
                            .font(.caption)
                        if item.count > 1 {
                            Text("\(item.count)")
                                .font(.caption2)
                                .foregroundStyle(isOutgoing ? .white.opacity(0.8) : .secondary)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(isOutgoing ? Color.white.opacity(0.2) : Color(.systemGray6))
                    )
                }
            }
        }
    }

    private var sortedReactions: [(emoji: String, count: Int)] {
        reactions
            .map { (emoji: $0.key, count: $0.value.count) }
            .filter { $0.count > 0 }
            .sorted { $0.count > $1.count }
    }
}
