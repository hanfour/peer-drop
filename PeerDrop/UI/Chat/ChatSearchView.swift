import SwiftUI

/// Search view for finding messages in chat history.
struct ChatSearchView: View {
    @ObservedObject var chatManager: ChatManager
    let peerID: String
    let onSelectMessage: (ChatMessage) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var results: [ChatMessage] = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search bar
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)

                    TextField("Search messages", text: $searchText)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Search messages")
                        .accessibilityHint("Type to search chat history")
                        .onChange(of: searchText) { newValue in
                            performSearch(query: newValue)
                        }

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                            results = []
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("Clear search")
                        .accessibilityHint("Double tap to clear search text")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding()

                Divider()

                // Results
                if results.isEmpty && !searchText.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("No messages found")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer()
                } else if results.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("Type to search messages")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer()
                } else {
                    List {
                        ForEach(results) { message in
                            SearchResultRow(message: message, searchText: searchText)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    onSelectMessage(message)
                                    dismiss()
                                }
                                .accessibilityHint("Double tap to jump to this message")
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func performSearch(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            results = []
            return
        }

        results = chatManager.searchMessages(query: trimmed, peerID: peerID)
    }
}

/// Row for displaying a search result.
struct SearchResultRow: View {
    let message: ChatMessage
    let searchText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Sender and time
            HStack {
                Text(message.isOutgoing ? "You" : (message.senderName ?? message.peerName))
                    .font(.subheadline.bold())
                    .foregroundStyle(message.isOutgoing ? .green : .blue)

                Spacer()

                Text(message.timestamp, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Message content with highlighted match
            if let text = message.text {
                HighlightedText(text: text, highlight: searchText)
                    .lineLimit(2)
            } else if let fileName = message.fileName {
                Label(fileName, systemImage: iconForMediaType(message.mediaType))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(searchResultAccessibilityLabel)
    }

    private var searchResultAccessibilityLabel: String {
        let sender = message.isOutgoing ? "You" : (message.senderName ?? message.peerName)
        if let text = message.text {
            return "\(sender): \(text)"
        } else if let fileName = message.fileName {
            return "\(sender): file \(fileName)"
        }
        return sender
    }

    private func iconForMediaType(_ type: String?) -> String {
        switch type {
        case "image": return "photo"
        case "video": return "video"
        case "voice": return "waveform"
        default: return "doc"
        }
    }
}

/// Text view that highlights matching portions.
struct HighlightedText: View {
    let text: String
    let highlight: String

    var body: some View {
        textWithHighlight()
    }

    private func textWithHighlight() -> Text {
        guard !highlight.isEmpty else {
            return Text(text)
        }

        let lowercasedText = text.lowercased()
        let lowercasedHighlight = highlight.lowercased()

        guard let range = lowercasedText.range(of: lowercasedHighlight) else {
            return Text(text)
        }

        let startIndex = text.distance(from: text.startIndex, to: range.lowerBound)
        let endIndex = text.distance(from: text.startIndex, to: range.upperBound)

        let prefix = String(text.prefix(startIndex))
        let match = String(text[text.index(text.startIndex, offsetBy: startIndex)..<text.index(text.startIndex, offsetBy: endIndex)])
        let suffix = String(text.suffix(text.count - endIndex))

        return Text(prefix) +
            Text(match).bold().foregroundColor(.yellow) +
            Text(suffix)
    }
}
