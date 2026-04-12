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
        PetWidgetEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (PetWidgetEntry) -> Void) {
        let snapshot = SharedPetState().read()
        completion(PetWidgetEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PetWidgetEntry>) -> Void) {
        let snapshot = SharedPetState().read()
        let entry = PetWidgetEntry(date: Date(), snapshot: snapshot)
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }
}

struct PetWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: PetSnapshot?
}

struct PetWidgetSmallView: View {
    let entry: PetWidgetEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            VStack(spacing: 4) {
                if let image = PetSnapshotRenderer.render(
                    body: snapshot.bodyType, level: snapshot.level, mood: snapshot.mood,
                    eyes: snapshot.eyeType, pattern: snapshot.patternType,
                    paletteIndex: snapshot.paletteIndex, scale: 8) {
                    Image(decorative: image, scale: 1.0)
                        .interpolation(.none)
                        .resizable()
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
                Text("No Pet Yet")
                    .font(.caption)
            }
            .widgetBackground()
        }
    }
}

struct PetWidgetCircularView: View {
    let entry: PetWidgetEntry

    var body: some View {
        if let snapshot = entry.snapshot,
           let image = PetSnapshotRenderer.render(
            body: snapshot.bodyType, level: snapshot.level, mood: snapshot.mood,
            eyes: snapshot.eyeType, pattern: snapshot.patternType,
            paletteIndex: snapshot.paletteIndex, scale: 4) {
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
        .configurationDisplayName("Pet")
        .description("See your pet at a glance.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}
