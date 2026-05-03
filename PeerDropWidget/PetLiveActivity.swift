import ActivityKit
import WidgetKit
import SwiftUI

@available(iOSApplicationExtension 16.2, *)
struct PetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PetActivityAttributes.self) { context in
            // Lock Screen / Banner
            HStack(spacing: 12) {
                petSprite()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text(context.attributes.petName).font(.headline)
                    ProgressView(value: context.state.expProgress).tint(.yellow)
                    Text(context.state.mood.displayName)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding()
            .activityBackgroundTint(.black.opacity(0.8))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    petSprite()
                        .frame(width: 48, height: 48)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(context.attributes.petName).font(.caption.bold())
                        Text("Lv.\(context.state.level.rawValue)").font(.caption2)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 4) {
                        ProgressView(value: context.state.expProgress).tint(.yellow)
                        Text(context.state.mood.displayName)
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                petSprite()
                    .frame(width: 24, height: 24)
            } compactTrailing: {
                Text(moodEmoji(context.state.mood)).font(.caption)
            } minimal: {
                petSprite()
                    .frame(width: 24, height: 24)
            }
        }
    }

    /// Reads the pre-rendered pet from the App Group bridge written by the
    /// main app's PetEngine.updateRenderedImage. SwiftUI scales the single
    /// loaded CGImage to each callsite's .frame() size — no per-scale render
    /// is needed (unlike the legacy PetSnapshotRenderer path).
    @ViewBuilder
    private func petSprite() -> some View {
        if let image = SharedRenderedPet().read() {
            Image(decorative: image, scale: 1.0)
                .interpolation(.none).resizable().aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "pawprint.fill")
        }
    }

    private func moodEmoji(_ mood: PetMood) -> String {
        switch mood {
        case .happy: return "😊"
        case .curious: return "🤔"
        case .sleepy: return "😴"
        case .lonely: return "😢"
        case .excited: return "🤩"
        case .startled: return "😱"
        }
    }
}
