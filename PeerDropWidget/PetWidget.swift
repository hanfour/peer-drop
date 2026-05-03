import WidgetKit
import SwiftUI

private extension View {
    @ViewBuilder
    func widgetBackground() -> some View {
        if #available(iOSApplicationExtension 17.0, *) {
            self.containerBackground(.fill.tertiary, for: .widget)
        } else {
            self.padding()
                .background(Color(UIColor.systemBackground))
        }
    }
}

struct PetWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> PetWidgetEntry {
        PetWidgetEntry(date: Date(), snapshot: nil, renderedImage: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (PetWidgetEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PetWidgetEntry>) -> Void) {
        let entry = currentEntry()
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }

    /// Builds the current entry by reading both the metadata snapshot and the
    /// pre-rendered CGImage from the App Group container. The main app writes
    /// the image via SharedRenderedPet during PetEngine.updateRenderedImage;
    /// the widget never runs the v4.0 PNG pipeline itself.
    private func currentEntry() -> PetWidgetEntry {
        let snapshot = SharedPetState().read()
        let renderedImage = SharedRenderedPet().read()
        return PetWidgetEntry(date: Date(), snapshot: snapshot, renderedImage: renderedImage)
    }
}

struct PetWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: PetSnapshot?
    /// Pre-rendered pet image from the main app's PetRendererV3 (PNG sprite
    /// + mood SF Symbol overlay), shipped via SharedRenderedPet App Group
    /// bridge. nil when the main app hasn't rendered yet (first install) or
    /// the bridge file isn't readable — view falls back to placeholder.
    let renderedImage: CGImage?
}

struct PetWidgetSmallView: View {
    let entry: PetWidgetEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            VStack(spacing: 4) {
                if let image = entry.renderedImage {
                    Image(decorative: image, scale: 1.0)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 80, height: 80)
                } else {
                    // Pre-render not yet available — show metadata-only fallback.
                    Image(systemName: "pawprint.fill")
                        .font(.largeTitle)
                        .frame(width: 80, height: 80)
                }
                if let name = snapshot.name {
                    Text(name).font(.caption).bold()
                }
                Text(snapshot.mood.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .widgetBackground()
        } else {
            VStack {
                Image(systemName: "pawprint.fill")
                    .font(.largeTitle)
                Text("pet_widget_no_pet")
                    .font(.caption)
            }
            .widgetBackground()
        }
    }
}

struct PetWidgetCircularView: View {
    let entry: PetWidgetEntry

    var body: some View {
        if let _ = entry.snapshot, let image = entry.renderedImage {
            Image(decorative: image, scale: 1.0)
                .interpolation(.none)
                .resizable()
                .widgetAccentable()
        } else {
            Image(systemName: "pawprint.fill")
                .widgetAccentable()
        }
    }
}

struct PetWidget: Widget {
    let kind = "PetWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PetWidgetProvider()) { entry in
            if #available(iOSApplicationExtension 17.0, *) {
                PetWidgetSmallView(entry: entry)
            } else {
                PetWidgetSmallView(entry: entry).padding()
            }
        }
        .configurationDisplayName(Text("pet_widget_name"))
        .description(Text("pet_widget_description"))
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}
