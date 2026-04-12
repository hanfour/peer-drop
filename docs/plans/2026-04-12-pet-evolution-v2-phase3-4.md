# Pet Evolution v2 — Phase 3+4 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add Dynamic Island Live Activity, Home/Lock Screen widgets, evolution effects, time-of-day mood, and remove legacy v1 renderer.

**Architecture:** New `PeerDropWidget` extension target sharing pet state via App Group (`group.com.hanfour.peerdrop`). `SharedPetState` wraps UserDefaults suite for cross-process state. `PetSnapshotRenderer` produces static CGImage for widget/island without full PetEngine. ActivityKit manages Live Activity lifecycle tied to app foreground/background.

**Tech Stack:** SwiftUI, WidgetKit, ActivityKit, XcodeGen, App Group

**Design doc:** `docs/plans/2026-04-12-pet-evolution-v2-phase3-4-design.md`

---

### Task 1: App Group + SharedPetState

**Files:**
- Modify: `PeerDrop/App/PeerDrop.entitlements` (add App Group)
- Modify: `project.yml` (add App Group entitlement)
- Create: `PeerDrop/Pet/Shared/SharedPetState.swift`
- Test: `PeerDropTests/SharedPetStateTests.swift`

**Step 1: Write failing tests**

```swift
// PeerDropTests/SharedPetStateTests.swift
import XCTest
@testable import PeerDrop

final class SharedPetStateTests: XCTestCase {

    func testWriteAndReadPetSnapshot() {
        let shared = SharedPetState(suiteName: nil) // use standard UserDefaults for test
        let snapshot = PetSnapshot(
            name: "Pixel",
            bodyType: .cat,
            eyeType: .dot,
            patternType: .none,
            level: .baby,
            mood: .happy,
            paletteIndex: 0,
            experience: 42,
            maxExperience: 500
        )
        shared.write(snapshot)
        let read = shared.read()
        XCTAssertNotNil(read)
        XCTAssertEqual(read?.name, "Pixel")
        XCTAssertEqual(read?.bodyType, .cat)
        XCTAssertEqual(read?.level, .baby)
        XCTAssertEqual(read?.experience, 42)
    }

    func testReadReturnsNilWhenEmpty() {
        let shared = SharedPetState(suiteName: nil)
        shared.clear()
        XCTAssertNil(shared.read())
    }
}
```

**Step 2: Run tests to verify they fail**

Expected: Compile error — `SharedPetState`, `PetSnapshot` not found

**Step 3: Implement SharedPetState**

```swift
// PeerDrop/Pet/Shared/SharedPetState.swift
import Foundation

struct PetSnapshot: Codable, Equatable {
    let name: String?
    let bodyType: BodyGene
    let eyeType: EyeGene
    let patternType: PatternGene
    let level: PetLevel
    let mood: PetMood
    let paletteIndex: Int
    let experience: Int
    let maxExperience: Int
}

class SharedPetState {
    static let appGroupID = "group.com.hanfour.peerdrop"
    private static let key = "petSnapshot"
    private let defaults: UserDefaults

    init(suiteName: String? = appGroupID) {
        if let suite = suiteName {
            self.defaults = UserDefaults(suiteName: suite) ?? .standard
        } else {
            self.defaults = .standard
        }
    }

    func write(_ snapshot: PetSnapshot) {
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Self.key)
        }
    }

    func read() -> PetSnapshot? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(PetSnapshot.self, from: data)
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}
```

**Step 4: Add App Group to entitlements**

Add to `PeerDrop/App/PeerDrop.entitlements`:
```xml
<key>com.apple.security.application-groups</key>
<array>
    <string>group.com.hanfour.peerdrop</string>
</array>
```

Add to `project.yml` under PeerDrop target entitlements properties:
```yaml
com.apple.security.application-groups:
  - group.com.hanfour.peerdrop
```

**Step 5: Run tests, verify pass**

Run: `xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' -only-testing:PeerDropTests/SharedPetStateTests -quiet 2>&1 | tail -15`

**Step 6: Commit**

```bash
xcodegen generate
git add PeerDrop/Pet/Shared/SharedPetState.swift PeerDrop/App/PeerDrop.entitlements \
  project.yml PeerDropTests/SharedPetStateTests.swift PeerDrop.xcodeproj
git commit -m "feat(pet): add App Group + SharedPetState for widget data sharing"
```

---

### Task 2: PetSnapshotRenderer + IslandPose

**Files:**
- Create: `PeerDrop/Pet/Shared/PetSnapshotRenderer.swift`
- Create: `PeerDrop/Pet/Shared/IslandPose.swift`
- Test: `PeerDropTests/PetSnapshotRendererTests.swift`

**Step 1: Write failing tests**

```swift
// PeerDropTests/PetSnapshotRendererTests.swift
import XCTest
@testable import PeerDrop

final class PetSnapshotRendererTests: XCTestCase {

    func testRenderCatBaby16x16() {
        let image = PetSnapshotRenderer.render(
            body: .cat, level: .baby, mood: .happy,
            eyes: .dot, pattern: .none, paletteIndex: 0, scale: 1)
        XCTAssertNotNil(image)
        XCTAssertEqual(image?.width, 16)
        XCTAssertEqual(image?.height, 16)
    }

    func testRenderEgg() {
        let image = PetSnapshotRenderer.render(
            body: .cat, level: .egg, mood: .curious,
            eyes: .dot, pattern: .none, paletteIndex: 0, scale: 1)
        XCTAssertNotNil(image)
    }

    func testRenderScaled128() {
        let image = PetSnapshotRenderer.render(
            body: .dog, level: .child, mood: .sleepy,
            eyes: .round, pattern: .stripe, paletteIndex: 3, scale: 8)
        XCTAssertEqual(image?.width, 128)
    }

    func testIslandPoseMapping() {
        XCTAssertEqual(IslandPose.from(mood: .sleepy), .sleeping)
        XCTAssertEqual(IslandPose.from(mood: .happy), .happy)
        XCTAssertEqual(IslandPose.from(mood: .lonely), .lonely)
        XCTAssertEqual(IslandPose.from(mood: .curious), .sitting)
    }
}
```

**Step 2: Implement**

```swift
// PeerDrop/Pet/Shared/IslandPose.swift
enum IslandPose: String, Codable, Hashable {
    case sitting, sleeping, happy, eating, pooping, lonely

    static func from(mood: PetMood) -> IslandPose {
        switch mood {
        case .sleepy: return .sleeping
        case .happy, .excited: return .happy
        case .lonely: return .lonely
        case .startled: return .sitting
        case .curious: return .sitting
        }
    }

    var action: PetAction {
        switch self {
        case .sitting: return .idle
        case .sleeping: return .sleeping
        case .happy: return .happy
        case .eating: return .eat
        case .pooping: return .poop
        case .lonely: return .idle
        }
    }
}
```

```swift
// PeerDrop/Pet/Shared/PetSnapshotRenderer.swift
import CoreGraphics

enum PetSnapshotRenderer {
    /// Render a static idle-frame CGImage from pet parameters.
    /// Usable from both main app and widget extension.
    static func render(body: BodyGene, level: PetLevel, mood: PetMood,
                       eyes: EyeGene, pattern: PatternGene,
                       paletteIndex: Int, scale: Int = 8) -> CGImage? {
        let palette: ColorPalette = level == .egg ? PetPalettes.egg : PetPalettes.all[paletteIndex]

        let indices: [[UInt8]]

        switch level {
        case .egg:
            indices = EggSpriteData.idle[0]
        case .baby, .child:
            let action: PetAction = .idle
            guard let bodyFrames = SpriteDataRegistry.sprites(for: body, stage: level)?[action],
                  !bodyFrames.isEmpty else { return nil }
            let bodyFrame = bodyFrames[0]
            let meta = SpriteDataRegistry.meta(for: body)

            let eyeData: [[UInt8]]?
            if let moodEyes = EyeSpriteData.moods[mood] {
                eyeData = moodEyes
            } else {
                eyeData = EyeSpriteData.sprites[eyes]
            }

            let patternData = pattern != .none ? PatternSpriteData.sprites[pattern] : nil

            indices = SpriteCompositor.composite(
                body: bodyFrame, eyes: eyeData, eyeAnchor: meta.eyeAnchor,
                pattern: patternData, patternMask: meta.patternMask)
        }

        return PaletteSwapRenderer.render(indices: indices, palette: palette, scale: scale)
    }
}
```

**Step 3: Run tests, verify pass**

**Step 4: Commit**

```bash
xcodegen generate
git add PeerDrop/Pet/Shared/PetSnapshotRenderer.swift PeerDrop/Pet/Shared/IslandPose.swift \
  PeerDropTests/PetSnapshotRendererTests.swift PeerDrop.xcodeproj
git commit -m "feat(pet): add PetSnapshotRenderer and IslandPose for widget/island rendering"
```

---

### Task 3: PetActivityAttributes + Live Activity Lifecycle

**Files:**
- Create: `PeerDrop/Pet/Shared/PetActivityAttributes.swift`
- Create: `PeerDrop/Pet/Engine/PetActivityManager.swift`
- Test: `PeerDropTests/PetActivityManagerTests.swift`

**Step 1: Write failing tests**

```swift
// PeerDropTests/PetActivityManagerTests.swift
import XCTest
@testable import PeerDrop

@MainActor
final class PetActivityManagerTests: XCTestCase {

    func testContentStateFromSnapshot() {
        let snapshot = PetSnapshot(
            name: "Pixel", bodyType: .cat, eyeType: .dot, patternType: .none,
            level: .baby, mood: .happy, paletteIndex: 0, experience: 100, maxExperience: 500)
        let state = PetActivityManager.contentState(from: snapshot)
        XCTAssertEqual(state.pose, .happy)
        XCTAssertEqual(state.mood, .happy)
        XCTAssertEqual(state.level, .baby)
        XCTAssertEqual(state.expProgress, 0.2, accuracy: 0.01)
    }

    func testContentStateExpProgressClamped() {
        let snapshot = PetSnapshot(
            name: nil, bodyType: .slime, eyeType: .dot, patternType: .none,
            level: .baby, mood: .curious, paletteIndex: 0, experience: 600, maxExperience: 500)
        let state = PetActivityManager.contentState(from: snapshot)
        XCTAssertEqual(state.expProgress, 1.0, accuracy: 0.01)
    }
}
```

**Step 2: Implement**

```swift
// PeerDrop/Pet/Shared/PetActivityAttributes.swift
import ActivityKit

struct PetActivityAttributes: ActivityAttributes {
    let petName: String
    let bodyType: BodyGene

    struct ContentState: Codable, Hashable {
        let pose: IslandPose
        let mood: PetMood
        let level: PetLevel
        let expProgress: Double
    }
}
```

```swift
// PeerDrop/Pet/Engine/PetActivityManager.swift
import Foundation
import ActivityKit

@MainActor
class PetActivityManager {
    private var currentActivity: Activity<PetActivityAttributes>?

    static func contentState(from snapshot: PetSnapshot) -> PetActivityAttributes.ContentState {
        let progress = snapshot.maxExperience > 0
            ? min(Double(snapshot.experience) / Double(snapshot.maxExperience), 1.0)
            : 0.0
        return PetActivityAttributes.ContentState(
            pose: IslandPose.from(mood: snapshot.mood),
            mood: snapshot.mood,
            level: snapshot.level,
            expProgress: progress
        )
    }

    func startActivity(snapshot: PetSnapshot) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = PetActivityAttributes(
            petName: snapshot.name ?? "Pet",
            bodyType: snapshot.bodyType
        )
        let state = Self.contentState(from: snapshot)
        do {
            currentActivity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: Date().addingTimeInterval(3600 * 8)),
                pushType: nil
            )
        } catch {
            // ActivityKit not available on this device
        }
    }

    func updateActivity(snapshot: PetSnapshot) {
        guard let activity = currentActivity else { return }
        let state = Self.contentState(from: snapshot)
        Task {
            await activity.update(.init(state: state, staleDate: Date().addingTimeInterval(3600 * 8)))
        }
    }

    func endActivity() {
        guard let activity = currentActivity else { return }
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        currentActivity = nil
    }
}
```

**Step 3: Wire into PetEngine / App lifecycle**

In `PeerDrop/App/PeerDropApp.swift` or `PeerDrop/Pet/Engine/PetEngine.swift`:
- On `scenePhase == .background` → call `activityManager.startActivity(snapshot:)`
- On `scenePhase == .active` → call `activityManager.endActivity()`
- On pet state change → call `activityManager.updateActivity(snapshot:)` and `sharedState.write(snapshot)`

Read `PeerDropApp.swift` first to understand existing lifecycle hooks.

**Step 4: Run tests, verify pass**

**Step 5: Commit**

```bash
xcodegen generate
git add PeerDrop/Pet/Shared/PetActivityAttributes.swift PeerDrop/Pet/Engine/PetActivityManager.swift \
  PeerDropTests/PetActivityManagerTests.swift PeerDrop.xcodeproj
git commit -m "feat(pet): add PetActivityAttributes + PetActivityManager for Live Activity lifecycle"
```

---

### Task 4: Widget Extension Target + PetWidget

**Files:**
- Modify: `project.yml` (add PeerDropWidget target)
- Create: `PeerDropWidget/PeerDropWidgetBundle.swift`
- Create: `PeerDropWidget/PetWidget.swift`
- Create: `PeerDropWidget/Info.plist`

**Step 1: Add Widget Extension target to project.yml**

```yaml
  PeerDropWidget:
    type: app-extension
    platform: iOS
    sources:
      - PeerDropWidget
      - path: PeerDrop/Pet/Shared
        group: Shared
      - path: PeerDrop/Pet/Renderer/PaletteSwapRenderer.swift
        group: Shared
      - path: PeerDrop/Pet/Renderer/SpriteCompositor.swift
        group: Shared
      - path: PeerDrop/Pet/Renderer/PetPalettes.swift
        group: Shared
      - path: PeerDrop/Pet/Sprites
        group: Shared
      - path: PeerDrop/Pet/Model/PetGenome.swift
        group: Shared
      - path: PeerDrop/Pet/Model/PetLevel.swift
        group: Shared
      - path: PeerDrop/Pet/Model/PetAction.swift
        group: Shared
      - path: PeerDrop/Pet/Model/PetMood.swift
        group: Shared
      - path: PeerDrop/Pet/Model/PetSurface.swift
        group: Shared
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.hanfour.peerdrop.widget
        DEVELOPMENT_TEAM: UK48R5KWLV
        CODE_SIGN_STYLE: Automatic
        MARKETING_VERSION: "2.0.1"
        CURRENT_PROJECT_VERSION: "1"
        GENERATE_INFOPLIST_FILE: "YES"
        INFOPLIST_KEY_CFBundleDisplayName: PeerDrop Widget
        INFOPLIST_KEY_NSHumanReadableCopyright: ""
    entitlements:
      path: PeerDropWidget/PeerDropWidget.entitlements
      properties:
        com.apple.security.application-groups:
          - group.com.hanfour.peerdrop
```

Also add dependency in main app target:
```yaml
    dependencies:
      - package: WebRTC
      - target: PeerDropWidget
```

**Step 2: Create widget files**

```swift
// PeerDropWidget/PeerDropWidgetBundle.swift
import WidgetKit
import SwiftUI

@main
struct PeerDropWidgetBundle: WidgetBundle {
    var body: some Widget {
        PetWidget()
        PetLiveActivity()
    }
}
```

```swift
// PeerDropWidget/PetWidget.swift
import WidgetKit
import SwiftUI

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
            .containerBackground(.fill.tertiary, for: .widget)
        } else {
            VStack {
                Image(systemName: "pawprint.fill")
                    .font(.largeTitle)
                Text("No Pet Yet")
                    .font(.caption)
            }
            .containerBackground(.fill.tertiary, for: .widget)
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
                PetWidgetSmallView(entry: entry)
                    .padding()
            }
        }
        .configurationDisplayName("Pet")
        .description("See your pet at a glance.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}
```

**Step 3: Create entitlements file**

Create `PeerDropWidget/PeerDropWidget.entitlements` with App Group.

**Step 4: Build to verify**

```bash
xcodegen generate
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' -quiet 2>&1 | grep error:
```

**Step 5: Commit**

```bash
git add project.yml PeerDropWidget/ PeerDrop.xcodeproj
git commit -m "feat(pet): add Widget Extension — Home Screen + Lock Screen pet widget"
```

---

### Task 5: PetLiveActivity — Dynamic Island Views

**Files:**
- Create: `PeerDropWidget/PetLiveActivity.swift`

**Step 1: Implement Live Activity views**

```swift
// PeerDropWidget/PetLiveActivity.swift
import ActivityKit
import WidgetKit
import SwiftUI

struct PetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PetActivityAttributes.self) { context in
            // Lock Screen / Banner view
            HStack(spacing: 12) {
                petSprite(body: context.attributes.bodyType, level: context.state.level,
                          mood: context.state.mood, scale: 4)
                    .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 4) {
                    Text(context.attributes.petName)
                        .font(.headline)
                    ProgressView(value: context.state.expProgress)
                        .tint(.yellow)
                    Text(context.state.mood.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .activityBackgroundTint(.black.opacity(0.8))

        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded
                DynamicIslandExpandedRegion(.leading) {
                    petSprite(body: context.attributes.bodyType, level: context.state.level,
                              mood: context.state.mood, scale: 4)
                        .frame(width: 48, height: 48)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(context.attributes.petName)
                            .font(.caption.bold())
                        Text("Lv.\(context.state.level.rawValue)")
                            .font(.caption2)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 4) {
                        ProgressView(value: context.state.expProgress)
                            .tint(.yellow)
                        Text(context.state.mood.displayName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                petSprite(body: context.attributes.bodyType, level: context.state.level,
                          mood: context.state.mood, scale: 2)
                    .frame(width: 24, height: 24)
            } compactTrailing: {
                Text(moodEmoji(context.state.mood))
                    .font(.caption)
            } minimal: {
                petSprite(body: context.attributes.bodyType, level: context.state.level,
                          mood: context.state.mood, scale: 2)
                    .frame(width: 24, height: 24)
            }
        }
    }

    @ViewBuilder
    private func petSprite(body: BodyGene, level: PetLevel, mood: PetMood, scale: Int) -> some View {
        if let image = PetSnapshotRenderer.render(
            body: body, level: level, mood: mood,
            eyes: .dot, pattern: .none, paletteIndex: 0, scale: scale) {
            Image(decorative: image, scale: 1.0)
                .interpolation(.none)
                .resizable()
                .aspectRatio(contentMode: .fit)
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
```

**Step 2: Build to verify**

```bash
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' -quiet 2>&1 | grep error:
```

**Step 3: Commit**

```bash
git add PeerDropWidget/PetLiveActivity.swift PeerDrop.xcodeproj
git commit -m "feat(pet): add Dynamic Island Live Activity — compact/expanded/minimal layouts"
```

---

### Task 6: Wire Live Activity to App Lifecycle

**Files:**
- Modify: `PeerDrop/App/PeerDropApp.swift`
- Modify: `PeerDrop/Pet/Engine/PetEngine.swift`

**Step 1: Read existing files**

Read `PeerDropApp.swift` and `PetEngine.swift` to understand current lifecycle hooks and `@Environment(\.scenePhase)` usage.

**Step 2: Add SharedPetState sync to PetEngine**

Add to PetEngine:
```swift
private let sharedState = SharedPetState()
private let activityManager = PetActivityManager()

func syncSharedState() {
    let snapshot = PetSnapshot(
        name: pet.name,
        bodyType: pet.genome.body,
        eyeType: pet.genome.eyes,
        patternType: pet.genome.pattern,
        level: pet.level,
        mood: pet.mood,
        paletteIndex: pet.genome.paletteIndex,
        experience: pet.experience,
        maxExperience: EvolutionRequirement.for(pet.level)?.requiredExperience ?? 999
    )
    sharedState.write(snapshot)
    activityManager.updateActivity(snapshot: snapshot)
}
```

Call `syncSharedState()` at end of `handleInteraction(_:)`, `handlePetStroke()`, `cleanPoop()`.

**Step 3: Add scenePhase handling to PeerDropApp**

```swift
.onChange(of: scenePhase) { newPhase in
    switch newPhase {
    case .background:
        petEngine.syncSharedState()
        petEngine.startLiveActivity()
    case .active:
        petEngine.endLiveActivity()
    default:
        break
    }
}
```

Add `startLiveActivity()` and `endLiveActivity()` wrapper methods to PetEngine that delegate to `activityManager`.

**Step 4: Build, verify no errors**

**Step 5: Commit**

```bash
git add PeerDrop/App/PeerDropApp.swift PeerDrop/Pet/Engine/PetEngine.swift
git commit -m "feat(pet): wire Live Activity to app lifecycle and sync SharedPetState"
```

---

### Task 7: Evolution Effects (Haptic + Flash)

**Files:**
- Modify: `PeerDrop/Pet/Engine/PetEngine.swift`
- Modify: `PeerDrop/Pet/UI/FloatingPetView.swift`
- Test: `PeerDropTests/PetEvolutionEffectTests.swift`

**Step 1: Write failing test**

```swift
// PeerDropTests/PetEvolutionEffectTests.swift
import XCTest
@testable import PeerDrop

@MainActor
final class PetEvolutionEffectTests: XCTestCase {

    func testEvolutionSetsShowFlashFlag() {
        var pet = PetState.newEgg()
        pet.level = .baby
        pet.genome.body = .cat
        pet.experience = 499
        pet.birthDate = Date().addingTimeInterval(-259201)
        let engine = PetEngine(pet: pet)
        engine.handleInteraction(.tap)
        XCTAssertEqual(engine.pet.level, .child)
        XCTAssertTrue(engine.showEvolutionFlash)
    }
}
```

**Step 2: Implement**

Add to PetEngine:
```swift
@Published var showEvolutionFlash = false
```

In `evolve(to:)`, add:
```swift
showEvolutionFlash = true
// Haptic feedback
let generator = UIImpactFeedbackGenerator(style: .heavy)
generator.impactOccurred()
// Auto-dismiss flash
Task {
    try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s
    showEvolutionFlash = false
}
```

Add flash overlay to FloatingPetView:
```swift
if engine.showEvolutionFlash {
    Color.white
        .ignoresSafeArea()
        .transition(.opacity)
        .allowsHitTesting(false)
}
```

**Step 3: Run test, verify pass**

**Step 4: Commit**

```bash
git add PeerDrop/Pet/Engine/PetEngine.swift PeerDrop/Pet/UI/FloatingPetView.swift \
  PeerDropTests/PetEvolutionEffectTests.swift
git commit -m "feat(pet): add evolution haptic feedback + white flash effect"
```

---

### Task 8: Time-of-Day Mood

**Files:**
- Modify: `PeerDrop/Pet/Engine/PetEngine.swift`
- Test: `PeerDropTests/PetTimeOfDayTests.swift`

**Step 1: Write failing tests**

```swift
// PeerDropTests/PetTimeOfDayTests.swift
import XCTest
@testable import PeerDrop

final class PetTimeOfDayTests: XCTestCase {

    func testNightTimeMoodIsSleepy() {
        // 23:00
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 23; comps.minute = 0
        let nightTime = Calendar.current.date(from: comps)!
        let result = PetTimeOfDayBehavior.suggestedMood(at: nightTime, lastInteraction: nightTime.addingTimeInterval(-7200))
        XCTAssertEqual(result, .sleepy)
    }

    func testDayTimeMoodIsNil() {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 14; comps.minute = 0
        let dayTime = Calendar.current.date(from: comps)!
        let result = PetTimeOfDayBehavior.suggestedMood(at: dayTime, lastInteraction: dayTime)
        XCTAssertNil(result, "Daytime should not force a mood")
    }

    func testNightTimeWithRecentInteractionIsNil() {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 23; comps.minute = 0
        let nightTime = Calendar.current.date(from: comps)!
        let result = PetTimeOfDayBehavior.suggestedMood(at: nightTime, lastInteraction: nightTime)
        XCTAssertNil(result, "Recent interaction should prevent forced sleepy")
    }
}
```

**Step 2: Implement**

```swift
// Add to PeerDrop/Pet/Engine/PetEngine.swift (or create a small helper)
enum PetTimeOfDayBehavior {
    /// Returns a suggested mood override for nighttime, or nil if no override.
    static func suggestedMood(at date: Date = Date(), lastInteraction: Date) -> PetMood? {
        let hour = Calendar.current.component(.hour, from: date)
        let isNight = hour >= 22 || hour < 6
        let recentlyInteracted = date.timeIntervalSince(lastInteraction) < 1800 // 30 min
        if isNight && !recentlyInteracted {
            return .sleepy
        }
        return nil
    }
}
```

Call from behavior loop (1s tick) in FloatingPetView or PetEngine:
```swift
if let forcedMood = PetTimeOfDayBehavior.suggestedMood(
    lastInteraction: pet.lastInteraction ?? pet.birthDate) {
    pet.mood = forcedMood
}
```

**Step 3: Run tests, verify pass**

**Step 4: Commit**

```bash
git add PeerDrop/Pet/Engine/PetEngine.swift PeerDropTests/PetTimeOfDayTests.swift
git commit -m "feat(pet): add time-of-day mood — nighttime auto-sleepy after 30min idle"
```

---

### Task 9: Legacy v1 Renderer Cleanup

**Files:**
- Delete: `PeerDrop/Pet/Renderer/PetRenderer.swift`
- Delete: `PeerDrop/Pet/Renderer/PetSpriteTemplates.swift`
- Delete: `PeerDrop/Pet/Renderer/PixelGrid.swift`
- Modify: `PeerDrop/Pet/UI/PixelView.swift` (remove old PixelView, keep SpriteImageView)
- Modify: `PeerDrop/Pet/Engine/PetEngine.swift` (remove renderedGrid, renderer v1, updateRenderedGrid)
- Modify: `PeerDrop/Pet/UI/GuestPetView.swift` (replace PixelView with SpriteImageView)
- Modify: `PeerDrop/Pet/UI/PetInteractionView.swift` (replace PixelView with SpriteImageView)
- Delete: `PeerDropTests/PetRendererTests.swift` (tests old renderer)
- Delete: `PeerDropTests/PixelGridTests.swift`

**Step 1: Read all affected files to understand usage**

Read GuestPetView.swift, PetInteractionView.swift, PetEngine.swift to see how they use `renderedGrid`, `PixelView`, `PetRenderer`, `PixelGrid`.

**Step 2: Update GuestPetView and PetInteractionView**

Replace `PixelView(grid: ..., palette: ..., displaySize: 128)` with `SpriteImageView(image: engine.renderedImage, displaySize: 128)` (or render inline with PetSnapshotRenderer).

**Step 3: Remove v1 from PetEngine**

Remove:
- `@Published private(set) var renderedGrid: PixelGrid = .empty()`
- `private let renderer = PetRenderer()`
- `updateRenderedGrid()` method
- Any calls to `updateRenderedGrid()`

**Step 4: Delete v1 files**

```bash
rm PeerDrop/Pet/Renderer/PetRenderer.swift
rm PeerDrop/Pet/Renderer/PetSpriteTemplates.swift
rm PeerDrop/Pet/Renderer/PixelGrid.swift
rm PeerDropTests/PetRendererTests.swift
rm PeerDropTests/PixelGridTests.swift
```

**Step 5: Clean up PixelView.swift**

Remove old `PixelView` struct, keep only `SpriteImageView`.

**Step 6: xcodegen + build + full test suite**

```bash
xcodegen generate
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' -quiet 2>&1 | grep error:
xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' -quiet 2>&1 | tail -10
```

Fix any remaining references to deleted types.

**Step 7: Commit**

```bash
git add -A
git commit -m "refactor(pet): remove legacy v1 renderer (PetRenderer, PetSpriteTemplates, PixelGrid)

Phase 3+4 complete: Dynamic Island, widgets, evolution effects,
time-of-day mood, legacy cleanup."
```

---

### Task 10: Performance Logging + Final Verification

**Files:**
- Modify: `PeerDrop/Pet/Renderer/SpriteCache.swift` (add hit/miss logging)

**Step 1: Add DEBUG logging to SpriteCache**

```swift
#if DEBUG
private var hits = 0
private var misses = 0

// In get():
if image != nil { hits += 1 } else { misses += 1 }
if (hits + misses) % 100 == 0 {
    print("[SpriteCache] hits: \(hits), misses: \(misses), rate: \(hits * 100 / max(hits + misses, 1))%")
}
#endif
```

**Step 2: Run full test suite**

```bash
xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' 2>&1 | grep -E "Executed.*tests"
```

Verify all tests pass (minus known simulator issues).

**Step 3: Commit**

```bash
git add PeerDrop/Pet/Renderer/SpriteCache.swift
git commit -m "perf(pet): add SpriteCache hit/miss logging in DEBUG builds"
```

---

## Phase 3+4 Deliverables Checklist

After all 10 tasks:
- [ ] App Group (`group.com.hanfour.peerdrop`) configured
- [ ] SharedPetState — cross-process pet state sharing
- [ ] PetSnapshotRenderer — static CGImage from pet params
- [ ] PetActivityAttributes + PetActivityManager — Live Activity lifecycle
- [ ] PeerDropWidget target — Home Screen (systemSmall) + Lock Screen (accessoryCircular)
- [ ] PetLiveActivity — Dynamic Island compact/expanded/minimal
- [ ] Live Activity wired to app foreground/background transitions
- [ ] Evolution haptic (.heavy) + white flash (0.3s)
- [ ] Time-of-day mood (nighttime auto-sleepy)
- [ ] Legacy v1 renderer removed (PetRenderer, PetSpriteTemplates, PixelGrid)
- [ ] SpriteCache performance logging
- [ ] All tests pass
