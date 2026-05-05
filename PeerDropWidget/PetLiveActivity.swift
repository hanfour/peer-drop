import ActivityKit
import WidgetKit
import SwiftUI

@available(iOSApplicationExtension 16.2, *)
struct PetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PetActivityAttributes.self) { context in
            // Read the pre-rendered bridge file ONCE per top-level closure.
            // The previous per-region helper was called from up to 4 region
            // builders — each invocation allocated a SharedRenderedPet and
            // hit NSFileCoordinator coordination, multiplying cross-process
            // sync overhead per render.
            let renderedImage = SharedRenderedPet().read()
            // Lock Screen / Banner
            HStack(spacing: 12) {
                petSprite(image: renderedImage)
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
            // Same once-per-closure read for the dynamic island — its 4
            // region builders all see the same hoisted image.
            let renderedImage = SharedRenderedPet().read()
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    petSprite(image: renderedImage)
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
                petSprite(image: renderedImage)
                    .frame(width: 24, height: 24)
            } compactTrailing: {
                Text(moodEmoji(context.state.mood)).font(.caption)
            } minimal: {
                petSprite(image: renderedImage)
                    .frame(width: 24, height: 24)
            }
        }
    }

    /// Renders the supplied pre-rendered CGImage (read from the App Group
    /// bridge) at the caller's .frame() size, or a placeholder if the bridge
    /// file isn't available yet. SwiftUI handles the per-region resize from
    /// one source CGImage — no per-scale render is needed.
    @ViewBuilder
    private func petSprite(image: CGImage?) -> some View {
        if let image {
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
