import SwiftUI

struct PetSecretChatRow: View {
    let entry: SocialEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("與 \(entry.partnerName ?? "???")").font(.caption).fontWeight(.medium)
                Spacer()
                Text(entry.date, style: .relative).font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(Array(entry.dialogue.enumerated()), id: \.offset) { _, line in
                HStack(spacing: 4) {
                    Text(line.speaker == "mine" ? "\u{1F423}" : "\u{1F425}").font(.caption2)
                    Text(line.text).font(.caption)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
