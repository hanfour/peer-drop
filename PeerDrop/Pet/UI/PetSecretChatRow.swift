import SwiftUI

struct PetSecretChatRow: View {
    let entry: SocialEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let genome = entry.partnerGenome,
                   let image = PetSnapshotRenderer.render(
                       body: genome.body, level: .baby, mood: .happy,
                       eyes: genome.eyes, pattern: genome.pattern,
                       paletteIndex: genome.paletteIndex, scale: 4) {
                    Image(decorative: image, scale: 1.0)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 32, height: 32)
                }
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
