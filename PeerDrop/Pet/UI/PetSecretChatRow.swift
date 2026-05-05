import SwiftUI

struct PetSecretChatRow: View {
    let entry: SocialEntry
    @State private var partnerImage: CGImage?
    /// View-lifetime renderer instance — lets the lastComposite memo survive
    /// across renders. SocialEntry is immutable so the input never changes
    /// after first render; with the memo, repeated body evaluations skip the
    /// composite work entirely.
    @State private var renderer = PetRendererV3()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let image = partnerImage {
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
        .task { await renderPartner() }
    }

    /// Renders the chat partner's pet via the v4.0 PNG pipeline. Synthesises
    /// stage = .baby, mood = .happy because SocialEntry only carries the
    /// partner's PetGenome (their level/mood at meeting time wasn't persisted
    /// in v3.x). The cache makes per-row cost negligible after first decode.
    @MainActor
    private func renderPartner() async {
        guard let genome = entry.partnerGenome else { return }
        partnerImage = try? await renderer.render(
            genome: genome,
            level: .baby,
            mood: .happy,
            direction: .east)
    }
}
