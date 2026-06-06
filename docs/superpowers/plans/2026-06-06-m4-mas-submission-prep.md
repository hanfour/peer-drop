# M4 — Mac App Store Submission Prep Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship PeerDrop for Mac to the App Store. First Mac binary lands in `WAITING_FOR_REVIEW` with metadata, screenshots, and IAP attached; iOS v6.0.0 (SPM rebuild) ships the same day.

**Architecture:** Mac binary uses the existing `PeerDropMac` target shipped in M2/M3. M4 is operational: un-stub the sidebar (M2 Task 6b residual) so screenshots show real UI, commission `Ringtone.caf`, build a `release_mac` fastlane lane (gym → pilot → deliver), translate metadata, capture Mac screenshots (3 sizes × 5 languages × light/dark), enable the macOS platform in ASC, set up bundle ID `com.hanfour.peerdrop.mac` capabilities (Push, Microphone, App Sandbox), re-attach the IAP tip jar via Playwright (matches v5.3.2 flow), write reviewer notes.

**Tech Stack:** Fastlane (`gym`, `pilot`, `deliver`, `snapshot`), Snapfile for macOS devices, App Store Connect API key (`fastlane/api_key.json`), Playwright (for IAP re-attach), Apple Developer portal (capability + bundle ID setup), ASC web UI for platform enablement.

**Spec reference:** `docs/superpowers/specs/2026-05-24-macos-port-design.md` §M4 (line 334). 4–6 days dev + 1–2 weeks Apple review buffer.

**Memory references (apply during execution):**
- `[[feedback-asc-iap-quirks]]` — 5 non-obvious IAP automation rules (Tasks 9b / 10)
- `[[feedback-capability-add-twostep-ship]]` — v5.3's lesson on adding capabilities (1: manually enable in Developer portal → click Save; 2: `fastlane run get_provisioning_profile force:true` to regenerate the profile). Directly applies to Tasks 3 + 5.
- Project memory `Language` section — 繁體中文台灣用語 / Japanese / Korean conventions (Task 7)

**Predecessors:** M3 (PR #59) merged into main.

## Investigation findings (verified before plan)

### What's ready

- `PeerDropMac` target builds clean on macOS — `PRODUCT_BUNDLE_IDENTIFIER: com.hanfour.peerdrop.mac`, `MARKETING_VERSION: 6.0.0`, sandbox + multicast + bluetooth + APNs + audio-input entitlements all set (M2 + M3 commits).
- Existing iOS fastlane infrastructure: `release` lane shape (build_app → upload_to_app_store → submit_for_review), reviewer-notes auto-load from `docs/release/v<version>-reviewer-notes.md`, ASC API key wired into gym for `-allowProvisioningUpdates`.
- iOS metadata in 5 languages at `fastlane/metadata/<lang>/`; copyright + categories + keywords + description + privacy URL all present.
- Snapfile already configured for 3 iOS devices + 5 languages.
- IAP tip jar lessons captured in `feedback-asc-iap-quirks` memory: ASCII-only display name, screenshot ≠ 1024×1024, first IAP must bind to a new binary, `submit:false` + Playwright attach flow.

### What's blocking

- **Mac sidebar sections are stubs** (`MacDetailRouter` returns `ContentUnavailableView` for Nearby/Trusted/Relay). M2 Task 6b deferred this. **Screenshots would show "Pick a section" placeholders** — Apple won't reject but they're bad marketing. Task 1 below un-stubs.
- **`Ringtone.caf` not commissioned** — `MacRingtonePlayer` falls back to looped `NSSound("Glass")` which sandboxed shipped builds may silence. **Must be added before MAS submission.** Task 2.
- **macOS platform not enabled on App ID** in App Store Connect. Manual one-time setup at ASC web UI. Task 11.
- **No Mac fastlane lane** — `release` is iOS-only (uses `build_app(scheme: "PeerDrop")` and `pilot` for TestFlight which is iOS-only-ish on Macs ← actually pilot supports macOS via `app_platform: "osx"`).
- **No Snapfile for macOS** — different device set, different `only_testing` target.
- **No `fastlane/metadata/macos/`** — needs a new sibling tree per ASC's macOS metadata model.
- **No Mac IAP attached** — needs Playwright re-attach (same pattern as v5.3.2 iOS).
- **No `docs/release/v6.0.0-reviewer-notes.md`**.

### File structure

**New**:
- `docs/release/v6.0.0-reviewer-notes.md` — reviewer notes for v6.0.0 (both iOS + macOS share the version).
- `fastlane/SnapfileMac` — macOS-specific snapshot config.
- `fastlane/metadata/macos/` (tree mirroring `fastlane/metadata/` for the Mac platform).
- `PeerDropMac/Resources/Ringtone.caf` — bundled ring asset.
- `PeerDropMacUITests/` (new test target) — UI tests for snapshot capture if we decide to use fastlane snapshot. Alternative: manual capture + check in PNGs.

**Modify**:
- `fastlane/Fastfile` — add `release_mac` lane + `screenshots_mac` lane + `submit_mac_only` for re-submission.
- `project.yml` — un-exclude Voice/PushStatusRow already done in M3; un-exclude or REPLACE the 8 remaining iOS-coupled files for proper sidebar content (NearbyTab, LibraryTab, RelayConnectView, etc.). Add `PeerDropMacUITests` target if going automated-snapshot route.
- `PeerDropMac/Views/MacDetailRouter.swift` — replace 3 stubs with real iOS view reuse (NearbyTab / LibraryTab / RelayConnectView).
- `fastlane/Snapfile` (or duplicate) — Mac variant.
- `docs/release/release-runbook.md` — Mac release section.
- `MEMORY.md` + `project-macos-port.md` — M4 ship status after merge.

## Task 1a: PlatformImage typealias infrastructure

**Files:**
- Create: `PeerDropMac/Adapters/PlatformImage+Mac.swift`
- Create: `PeerDrop/UI/Components/PlatformImage+iOS.swift`

This task ships **independently and merges before Task 1b** so the typealias is in place before any REPLACE-file refactor depends on it. Small, low-risk PR.

- [ ] **Step 1: macOS typealias**

```swift
// PeerDropMac/Adapters/PlatformImage+Mac.swift
#if canImport(AppKit)
import AppKit
import SwiftUI

typealias PlatformImage = NSImage

extension Image {
    init(platformImage: PlatformImage) {
        self.init(nsImage: platformImage)
    }
}
#endif
```

- [ ] **Step 2: iOS typealias**

```swift
// PeerDrop/UI/Components/PlatformImage+iOS.swift
#if canImport(UIKit)
import UIKit
import SwiftUI

typealias PlatformImage = UIImage

extension Image {
    init(platformImage: PlatformImage) {
        self.init(uiImage: platformImage)
    }
}
#endif
```

- [ ] **Step 3: Build + commit + open PR**

```bash
xcodegen generate
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' 2>&1 | tail -3
xcodebuild build -scheme PeerDropMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
git add PeerDropMac/Adapters/PlatformImage+Mac.swift PeerDrop/UI/Components/PlatformImage+iOS.swift PeerDrop.xcodeproj/project.pbxproj
git commit -m "feat(m4): PlatformImage typealias infrastructure (1a/2)

Adds typealias PlatformImage = NSImage on macOS, UIImage on iOS,
plus Image(platformImage:) initializer. No call sites changed yet
— Task 1b will swap UIImage/NSImage direct uses across the 8
REPLACE files.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

Merge 1a, then open 1b as a separate PR. Splitting keeps the typealias change reviewable as a discrete refactor that other tasks (Task 6 UI tests, Task 9 ship) can safely depend on.

---

## Task 1b: Un-stub the Mac sidebar (M2 Task 6b residual)

**Files:**
- Modify: `project.yml` (un-exclude 9 files in PeerDropMac sources)
- Modify: `PeerDrop/UI/Discovery/NearbyTab.swift` — add macOS gates
- Modify: `PeerDrop/UI/Library/LibraryTab.swift` — add macOS gates
- Modify: `PeerDrop/UI/Relay/RelayConnectView.swift` — add macOS gates
- Modify: `PeerDrop/UI/Transfer/FilePickerView.swift` — replace `UIDocumentPickerViewController` with `NSOpenPanel` via `#if`
- Modify: `PeerDrop/UI/Connection/ConnectionQRView.swift` — `UIImage` QR → `NSImage` via `#if`
- Modify: `PeerDrop/UI/Settings/UserProfileView.swift` — `UIImage` avatar → `NSImage` via `#if`
- Modify: `PeerDrop/UI/Chat/ChatView.swift` — `PhotosUI` picker gated `#if os(iOS)`; macOS uses NSOpenPanel for file attach
- Modify: `PeerDrop/UI/Chat/ChatBubbleView.swift` — `Image(uiImage:)` thumbnails → cross-platform `Image(decorative: cgImage)` path
- Modify: `PeerDrop/UI/Chat/MediaPreviewView.swift` — `UIImage` decode → `CGImage` via `#if`
- Modify: `PeerDropMac/Views/MacDetailRouter.swift` — wire NearbyTab/LibraryTab/RelayConnectView in place of stubs

**Execution model:** This task is best executed with `superpowers:subagent-driven-development` (3-4 implementer + reviewer rounds), one round per 2-3 files. Single-shot implementer over 9 files has too high a blast radius — if one fails the others get stuck.

- [ ] **Step 1: Audit each REPLACE file's iOS-only API list**

For each of the 9 files un-excluded by this task, list:
- Concrete iOS APIs used (UIKit type / SwiftUI iOS-only modifier / PhotosUI / UIDocumentPicker / UIPasteboard)
- macOS equivalent (NSOpenPanel / NSImage / NSPasteboard / NSWorkspace / etc.)
- Whether `#if canImport(UIKit)` gating works OR a full rewrite is needed

Report inline at the top of each file as a `// MARK: - macOS port notes` block before editing — so the rationale survives the diff.

- [ ] **Step 2: Use `Image(platformImage:)` at call sites**

The typealias and initializer were merged in Task 1a. In each REPLACE file, swap `Image(uiImage: img)` for `Image(platformImage: img)` — both platforms now build.

- [ ] **Step 3: Replace UIDocumentPickerViewController with NSOpenPanel**

In `FilePickerView.swift` + `Settings/DocumentPickerView.swift`:

```swift
#if canImport(UIKit)
import UniformTypeIdentifiers
// existing UIDocumentPickerViewController UIViewControllerRepresentable
#elseif canImport(AppKit)
import AppKit

struct FilePickerView: View {
    let onPicked: ([URL]) -> Void

    var body: some View {
        Button("Pick Files") {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            if panel.runModal() == .OK {
                onPicked(panel.urls)
            }
        }
    }
}
#endif
```

- [ ] **Step 4: QR rendering cross-platform**

`ConnectionQRView.swift` + `RelayConnectView.swift` both render QR codes via `CIImage.transformed(by:) → UIImage`. Refactor through `CGImage` (which is cross-platform):

```swift
private func renderQR(_ string: String) -> CGImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.setValue(string.data(using: .utf8), forKey: "inputMessage")
    filter.setValue("H", forKey: "inputCorrectionLevel")
    guard let ciImage = filter.outputImage else { return nil }
    let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
    return CIContext().createCGImage(scaled, from: scaled.extent)
}
```

Then `Image(decorative: cgImage, scale: 1.0)` at the call site. Works on both platforms.

- [ ] **Step 5: ChatView PhotosUI gate**

`ChatView.swift` uses `PhotosUI.PhotosPicker`. On macOS the equivalent is `NSOpenPanel` filtered to image types. Gate:

```swift
#if canImport(PhotosUI) && os(iOS)
import PhotosUI
PhotosPicker(...) { ... }
#elseif canImport(AppKit)
Button("Pick Image") {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image]
    panel.canChooseFiles = true
    if panel.runModal() == .OK, let url = panel.urls.first {
        // Same callback as PhotosPicker's onSelect
    }
}
#endif
```

- [ ] **Step 6: ChatBubbleView image decode path**

Use the new `PlatformImage` typealias + a `CGImage`-backed decode through `ImageCache`. The cache itself stores `CGImage` (already cross-platform); the SwiftUI side calls `Image(decorative:scale:)`.

- [ ] **Step 7: Drop excludes from project.yml**

Remove the following from `PeerDropMac` excludes block:
- `Discovery/NearbyTab.swift`
- `Library/LibraryTab.swift`
- `Relay/RelayConnectView.swift`
- `Transfer/FilePickerView.swift`
- `Connection/ConnectionQRView.swift`
- `Settings/UserProfileView.swift`
- `Chat/ChatView.swift`
- `Chat/MediaPreviewView.swift`
- `Chat/ChatBubbleView.swift`

Keep excluded (genuinely iOS-only):
- `Chat/CameraPickerView.swift` (UIImagePickerController — no macOS camera UI in M4 scope)
- `ContentView.swift` (iOS root TabView)
- `Settings/SettingsView.swift` (replaced by MacSettingsView)
- `Settings/TipJarSection.swift` (StoreKit IAP — M4 ships Mac IAP separately)
- `Transfer/ClipboardShareView.swift` (UIImage + UIPasteboard — niche)
- `Connection/ConnectionView.swift`, `Discovery/DiscoveryView.swift`, `Connection/ConnectedTab.swift` (iOS-shaped tab containers; MacContentView replaces)

- [ ] **Step 8: Wire MacDetailRouter to real views**

```swift
// PeerDropMac/Views/MacDetailRouter.swift
struct MacDetailRouter: View {
    let section: MacSidebarSection?
    @EnvironmentObject var connectionManager: ConnectionManager

    var body: some View {
        switch section {
        case .nearby:  NearbyTab().environmentObject(connectionManager)
        case .trusted: LibraryTab().environmentObject(connectionManager)
        case .relay:   RelayConnectView().environmentObject(connectionManager)
        case .pet:     PetSectionView()
        case .none:    ContentUnavailableView(...)
        }
    }
}
```

Delete the three `Mac*SectionStub` types.

- [ ] **Step 9: Build verify**

```bash
xcodegen generate
xcodebuild build -scheme PeerDropMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' 2>&1 | tail -3
xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' 2>&1 | grep "Executed " | tail -2
```

Expected: both BUILD SUCCEEDED. iOS test baseline preserved (635 / 0).

- [ ] **Step 10: Commit**

```bash
git add PeerDrop/UI/ PeerDropMac/Views/MacDetailRouter.swift PeerDropMac/Adapters/PlatformImage+Mac.swift PeerDrop/UI/Components/PlatformImage+iOS.swift project.yml PeerDrop.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
feat(m4): un-stub Mac sidebar — Nearby / Trusted / Relay real content

M2 Task 6b residual: 9 iOS-coupled files cross-platformed via
#if canImport(UIKit) / #elseif canImport(AppKit) gates and the new
PlatformImage typealias + Image(platformImage:) initializer.

  - FilePickerView / DocumentPickerView: UIDocumentPickerViewController
    → NSOpenPanel on macOS
  - ConnectionQRView / RelayConnectView: CIImage → CGImage → Image
    (cross-platform — was UIImage-coupled)
  - UserProfileView: avatar via PlatformImage typealias
  - ChatView: PhotosPicker (iOS) / NSOpenPanel (macOS) gated
  - ChatBubbleView + MediaPreviewView: CGImage-backed cache path
  - MacDetailRouter: 3 stubs replaced with NearbyTab / LibraryTab /
    RelayConnectView reuse

project.yml: 9 entries removed from PeerDropMac excludes.

iOS xcodebuild + macOS xcodebuild both green. iOS test baseline
635/0 preserved.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Commission and bundle `Ringtone.caf`

**Files:**
- Create: `PeerDropMac/Resources/Ringtone.caf`

**Human action required.** Suggested sources:

1. CC0 from Freesound (e.g. search "phone ring loop"). Convert:
   ```bash
   afconvert -d aac -f caff Source.aiff PeerDropMac/Resources/Ringtone.caf
   ```
2. Or commission a short branded ring (~5s, loopable, mono, 44.1 kHz, ≤6s, ~50 KB).

Verification:
```bash
afinfo PeerDropMac/Resources/Ringtone.caf  # should report mono AAC, 44.1 kHz, ~5s
```

- [ ] **Commit**

```bash
git add PeerDropMac/Resources/Ringtone.caf
git commit -m "asset(m4): bundle Ringtone.caf for incoming-call playback

Sandboxed apps can't reference /System/Library/Sounds/, so the ring
must be in-bundle. Source: <CC0 link or commission ref>. Format: AAC
in CAF container, mono 44.1 kHz, ~5s loopable. Replaces the dev-only
NSSound('Glass') fallback in MacRingtonePlayer.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Apple Developer Portal — enable Mac capabilities on bundle ID

**Files:** (manual portal work, no code commit)

- [ ] **Step 1: Confirm App ID `com.hanfour.peerdrop.mac`**

Login to developer.apple.com → Certificates, Identifiers & Profiles → Identifiers. If `com.hanfour.peerdrop.mac` doesn't exist:
- Create as macOS App ID, description "PeerDrop for Mac"
- Capabilities: enable App Sandbox, Push Notifications, Network Extensions (if needed), Microphone (audio-input)

If it exists, verify the capability list matches the entitlements file (`PeerDropMac/App/PeerDrop-Mac.entitlements`).

- [ ] **Step 2: Provisioning profile regeneration**

```bash
fastlane run get_provisioning_profile force:true \
  app_identifier:"com.hanfour.peerdrop.mac" \
  platform:"macos" \
  development:false
```

This downloads a fresh Mac App Store provisioning profile and the corresponding distribution cert reference.

- [ ] **Step 3: Verify in Keychain Access**

Confirm "Apple Distribution: <team name>" certificate present and the new `.provisionprofile` is in `~/Library/MobileDevice/Provisioning Profiles/` (path may differ — `~/Library/Developer/Xcode/UserData/Provisioning Profiles/` on newer Xcode).

---

## Task 4: App Store Connect — enable macOS platform

**Files:** (manual ASC web UI work, no code commit)

- [ ] **Step 1: Add macOS to the existing App record**

ASC → My Apps → PeerDrop → general info → Platforms → add macOS. This creates a sibling "Mac App Store" entry alongside the existing "iOS App". Bundle ID picker: `com.hanfour.peerdrop.mac` from the dropdown (created in Task 3).

- [ ] **Step 2: Mac-specific app info**

ASC will request:
- Mac App category (likely Utilities → Networking / File Sharing)
- Subtitle (≤30 chars per language)
- Promotional text (170 chars, optional)
- Description (full, can copy iOS then trim)
- Keywords (100 chars including commas)
- Support URL + Marketing URL
- Privacy Policy URL — reuse iOS URL
- Copyright (same as iOS)
- Age rating — re-confirm 4+

Most of these reuse iOS values; capture per-platform overrides in the metadata directory in Task 7.

- [ ] **Step 3: System requirements**

ASC asks min macOS version. Match `MACOSX_DEPLOYMENT_TARGET: "14.0"` from `project.yml`. Add note: "Microphone access required for voice calls".

---

## Task 5: `release_mac` fastlane lane

**Files:**
- Modify: `fastlane/Fastfile`

- [ ] **Step 1: Add lane**

```ruby
desc "Build + upload + submit Mac App Store binary"
lane :release_mac do |options|
  # ASC API key (reuse iOS pattern)
  api_key_path = File.expand_path("api_key.json", __dir__)
  data = JSON.parse(File.read(api_key_path))
  app_store_connect_api_key(
    key_id:      data["key_id"],
    issuer_id:   data["issuer_id"],
    key_content: data["key"],
    duration:    1200,
    in_house:    false
  )

  # Reviewer notes auto-load (same scheme as release lane)
  version = File.read(File.expand_path("../project.yml", __dir__))[/MARKETING_VERSION:\s*"([^"]+)"/, 1]
  notes_path = File.expand_path("../docs/release/v#{version}-reviewer-notes.md", __dir__)
  review_info = nil
  if File.exist?(notes_path)
    content = File.read(notes_path)
    if (m = content.match(/<!-- BEGIN_PASTE.*?-->(.*?)<!-- END_PASTE -->/m))
      body = m[1].strip
      if body.length > 4000
        UI.user_error!("Reviewer notes exceed 4000 chars (#{body.length}). Trim before release.")
      end
      review_info = { notes: body }
    end
  end

  # Build (gym, scheme PeerDropMac, configuration Release)
  build_app(
    scheme: "PeerDropMac",
    configuration: "Release",
    export_method: "app-store",
    output_directory: "./fastlane/build",
    output_name: "PeerDrop-Mac.pkg",
    xcargs: "-allowProvisioningUpdates"
  )

  # Upload to TestFlight (pilot supports macOS via app_platform: 'osx')
  upload_to_testflight(
    skip_waiting_for_build_processing: false,
    app_platform: "osx",
    apple_id: "6759594513"
  )

  # Upload metadata + screenshots
  upload_to_app_store(
    platform: "osx",
    skip_screenshots: false,
    skip_metadata: false,
    metadata_path: "./fastlane/metadata/macos",
    screenshots_path: "./fastlane/screenshots_mac",
    force: true,
    submit_for_review: options.fetch(:submit, true),
    submission_information: review_info ? { notes: review_info[:notes] } : nil,
    automatic_release: false,
    precheck_include_in_app_purchases: false  # IAP attached separately via Playwright
  )
end
```

- [ ] **Step 2: Add `check_status_mac` + `submit_mac_only`**

Mirror the iOS lanes with `platform: "osx"` filter. Reuse the iOS implementation pattern; substitute `app_platform: "osx"` everywhere.

- [ ] **Step 3: Dry-run lint**

```bash
fastlane lanes 2>&1 | grep release_mac
```

Verifies the lane parses.

- [ ] **Step 4: Commit**

```bash
git add fastlane/Fastfile
git commit -m "feat(m4): release_mac fastlane lane (gym → pilot → deliver)

Mirrors the iOS release lane shape but with platform: 'osx', schema
PeerDropMac, configuration Release, and metadata path
./fastlane/metadata/macos. precheck_include_in_app_purchases: false
because Mac IAP is attached separately via Playwright (matches the
v5.3.2 iOS pattern; Spaceship still lacks an attach API).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Mac snapshot infrastructure (`SnapfileMac` + UI tests)

**Files:**
- Create: `fastlane/SnapfileMac`
- Create: `PeerDropMacUITests/MacSnapshotTests.swift` (new test target)
- Modify: `project.yml` (add `PeerDropMacUITests` target)
- Modify: `fastlane/Fastfile` (add `screenshots_mac` lane)

- [ ] **Step 1: Create the test target**

In `project.yml` add:

```yaml
  PeerDropMacUITests:
    type: bundle.ui-testing
    platform: macOS
    sources:
      - path: PeerDropMacUITests
    dependencies:
      - target: PeerDropMac
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.peerdrop.mac.uitests
        DEVELOPMENT_TEAM: UK48R5KWLV
```

- [ ] **Step 2: Write 5 screenshot tests**

`PeerDropMacUITests/MacSnapshotTests.swift`:

```swift
import XCTest

final class MacSnapshotTests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-SCREENSHOT_MODE", "1"]
        setupSnapshot(app)
        app.launch()
    }

    func test_01_Nearby() {
        snapshot("01_Nearby")
    }

    func test_02_Chat() {
        app.tables.cells.firstMatch.click()  // open a peer
        snapshot("02_Chat")
    }

    func test_03_Pet() {
        app.outlines.cells["Pet"].click()
        snapshot("03_Pet")
    }

    func test_04_Settings() {
        app.menuItems["Settings…"].click()
        snapshot("04_Settings")
    }

    func test_05_VoiceCall() {
        // SCREENSHOT_MODE pre-stages an incoming-call panel
        snapshot("05_IncomingCall")
    }
}
```

Add a `MacSnapshotTestsDark` mirror that flips `NSApp.appearance = .darkAqua` in `setUp`.

- [ ] **Step 3: Create SnapfileMac**

```ruby
scheme("PeerDropMacUITests")
output_directory("./fastlane/screenshots_mac")
devices(["Mac"])  # snapshot uses host Mac; resolution = host screen
languages(["en-US", "zh-Hant", "zh-Hans", "ja", "ko"])
launch_arguments(["-SCREENSHOT_MODE 1"])
clear_previous_screenshots(true)
only_testing([
  "PeerDropMacUITests/MacSnapshotTests",
  "PeerDropMacUITests/MacSnapshotTestsDark"
])
```

Note: macOS snapshot devices list is "Mac" + the host resolution. App Store accepts 1280×800 / 1440×900 / 2560×1600 / 2880×1800 — multiple resolutions need separate snapshot runs OR manual export from one high-DPI capture.

- [ ] **Step 4: Add `screenshots_mac` lane**

```ruby
desc "Capture macOS screenshots"
lane :screenshots_mac do
  capture_mac_screenshots(
    scheme: "PeerDropMacUITests",
    output_directory: "./fastlane/screenshots_mac",
    clear_previous_screenshots: true,
    localize_simulator: false  # macOS uses host locale
  )
end
```

- [ ] **Step 5: Smoke run**

```bash
fastlane screenshots_mac
```

Inspect `fastlane/screenshots_mac/<lang>/` for 5 PNG per language × 2 themes.

- [ ] **Step 6: Commit**

```bash
git add fastlane/SnapfileMac fastlane/Fastfile PeerDropMacUITests/ project.yml PeerDrop.xcodeproj/project.pbxproj
git commit -m "feat(m4): macOS snapshot infrastructure (SnapfileMac + UI test target)

PeerDropMacUITests target produces 5 screenshots × 2 themes ×
5 languages via fastlane snapshot. SCREENSHOT_MODE arg pre-stages
peer rows + Pet + incoming-call panel (matches iOS pattern).

screenshots_mac lane wraps the capture; output lands in
fastlane/screenshots_mac/<lang>/.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Translate metadata to `fastlane/metadata/macos/`

**Files:**
- Create: `fastlane/metadata/macos/{en-US,zh-Hant,zh-Hans,ja,ko}/`
- Create: `fastlane/metadata/macos/copyright.txt`
- Create: `fastlane/metadata/macos/primary_category.txt`

- [ ] **Step 1: Mirror the directory structure**

```bash
mkdir -p fastlane/metadata/macos/{en-US,zh-Hant,zh-Hans,ja,ko}
cp fastlane/metadata/copyright.txt fastlane/metadata/macos/
cp fastlane/metadata/primary_category.txt fastlane/metadata/macos/  # may differ; verify
```

- [ ] **Step 2: Per-language files**

For each language, create (copy from iOS as starting point, then edit):
- `name.txt` — app name (≤30 chars)
- `subtitle.txt` — ≤30 chars
- `description.txt` — full description
- `keywords.txt` — ≤100 chars including commas
- `marketing_url.txt` — same URL as iOS
- `privacy_url.txt` — same URL as iOS
- `support_url.txt` — same URL as iOS
- `promotional_text.txt` — ≤170 chars (optional, can omit)
- `release_notes.txt` — what's new in v6.0.0 (Mac-specific: "PeerDrop is now on Mac! Voice calls, file transfer, secure pairing — all native.")

Translate via:
1. Read iOS `fastlane/metadata/<lang>/description.txt`
2. Adapt for Mac (replace "iPhone" / "iPad" with "Mac", add Mac-specific value props: menu bar item, multi-window chat)
3. Save to `fastlane/metadata/macos/<lang>/description.txt`

Use existing 繁體中文台灣用語 / Japanese / Korean conventions from iOS metadata.

- [ ] **Step 3: Commit**

```bash
git add fastlane/metadata/macos/
git commit -m "i18n(m4): macOS metadata in 5 languages (mirrored from iOS)

en-US / zh-Hant / zh-Hans / ja / ko. Subtitle / description /
keywords / release notes all adapted for Mac context — replaces
'iPhone / iPad' wording with 'Mac', adds menu-bar + multi-window
chat value props.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Reviewer notes for v6.0.0

**Files:**
- Create: `docs/release/v6.0.0-reviewer-notes.md`

- [ ] **Step 1: Template**

```markdown
# v6.0.0 Reviewer Notes

## What's new (both platforms)
- iOS: SPM rebuild — no user-facing change, codebase modularised into PeerDropKit (6 modules).
- macOS: **new Mac app** (com.hanfour.peerdrop.mac). Bidirectional voice with iPhone, drag-and-drop file transfer, menu bar item, multi-window chat.

## How to test the Mac app
1. Install on a Mac running macOS 14+.
2. Install PeerDrop on an iPhone (linked App Store record).
3. Pair the devices via SAS (Settings → Pair Device → scan QR).
4. iPhone → Mac voice call: tap phone icon on iPhone in the Mac peer row. Mac shows the floating panel; Accept to connect.
5. Drag a file from Finder onto the menu bar PeerDrop icon → confirmation sheet → peer picker → send.

## Sandbox + entitlements
- `com.apple.security.app-sandbox` (required)
- `com.apple.security.network.client` + `.network.server` for P2P + relay
- `com.apple.security.device.audio-input` for voice capture
- `com.apple.developer.networking.multicast` for Bonjour discovery
- `aps-environment = production` for voice-call wake push
- No `com.apple.security.files.all` — only `user-selected.read-write`

## Known limitations
- Focus mode opacity: macOS 14 does not expose Focus state to third-party apps; `DNDFilter` reads `UNUserNotificationCenter` sound/center settings only.

## Anti-fraud / privacy
- E2EE for chat (X3DH + Double Ratchet), peer-to-peer file transfer prefers local Wi-Fi, relay falls back via Cloudflare Worker (Edge-encrypted).
- No third-party SDKs, no analytics, no IDFA.

<!-- BEGIN_PASTE -->
(Reviewer notes copy below this marker — fastlane uploads only this section. Max 4000 chars.)
<!-- END_PASTE -->
```

- [ ] **Step 2: Verify char count of BEGIN_PASTE block**

```bash
python3 -c "import re; t=open('docs/release/v6.0.0-reviewer-notes.md').read(); print(len(re.search(r'<!-- BEGIN_PASTE.*?-->(.*?)<!-- END_PASTE -->', t, re.DOTALL).group(1)))"
```

Must be ≤ 4000. Trim if needed.

- [ ] **Step 3: Commit**

```bash
git add docs/release/v6.0.0-reviewer-notes.md
git commit -m "docs(m4): v6.0.0 reviewer notes

Mac-specific section calls out: voice calling test steps, sandbox
entitlement list, Focus mode opacity limitation. BEGIN_PASTE block
verified under 4000 chars.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 9a: Bump iOS MARKETING_VERSION to 6.0.0 + ship iOS

**Files:** Modify `project.yml`

iOS v6.0.0 is the SPM rebuild ship — same-day with the first Mac binary per spec §M4. Handled as a separate task so its history is clean and reviewers can audit the iOS-only side independently.

- [ ] **Step 1: Bump iOS MARKETING_VERSION**

```bash
grep "MARKETING_VERSION" project.yml
```

If PeerDrop target still says `MARKETING_VERSION: "5.4.0"`, edit to `"6.0.0"` and:

```bash
xcodegen generate
```

Confirms `CFBundleShortVersionString` will resolve to 6.0.0 in the archive.

- [ ] **Step 2: Run iOS release lane**

```bash
fastlane release
```

Full iOS submit-for-review pipeline (build → upload → submit). Reviewer notes auto-load from `docs/release/v6.0.0-reviewer-notes.md` (created in Task 8). Total wall time ~6 min.

- [ ] **Step 3: Verify**

```bash
fastlane check_status
```

Expected: PeerDrop v6.0.0 (iOS), build N, `WAITING_FOR_REVIEW`.

- [ ] **Step 4: Commit version bump**

```bash
git add project.yml PeerDrop.xcodeproj/project.pbxproj
git commit -m "release: bump iOS to v6.0.0 for SPM-rebuild ship

Coincides with first Mac binary submission per spec §M4. Same-day
ship for both platforms; iOS user-facing changes are zero (SPM
modularisation is internal)."
```

---

## Task 9b: Cut v6.0.0 Mac binary + upload (NO submit)

**Files:** (none — runs `fastlane release_mac submit:false`)

- [ ] **Step 1: Confirm Mac MARKETING_VERSION = 6.0.0**

```bash
grep -A1 "PeerDropMac:" project.yml | grep MARKETING
```

Already set at M2; verify it didn't drift.

- [ ] **Step 2: Run `release_mac` with submit:false**

```bash
fastlane release_mac submit:false
```

This:
- Builds the .pkg
- Uploads to TestFlight (Mac App Store internal track)
- Uploads metadata + screenshots
- **Does NOT** submit for review — version sits in `PREPARE_FOR_SUBMISSION` so IAP can be attached

Expected: total wall time ~10 min. ASC web UI should show v6.0.0 (macOS) in `PREPARE_FOR_SUBMISSION`.

- [ ] **Step 3: Verify**

```bash
fastlane check_status_mac
# or open https://appstoreconnect.apple.com/apps/6759594513/distribution/macos
```

Expected: v6.0.0 macOS, build 1, "Prepare for Submission".

---

## Task 10: Attach Mac IAP tip jar via Playwright (re-use v5.3.2 flow)

**Files:** (Playwright script — `scripts/iap-attach-mac.ts` or reuse existing)

- [ ] **Step 1: Create or duplicate the existing IAP-attach Playwright script**

The v5.3.2 iOS flow lives at (likely) `scripts/iap-attach.ts` or in a shell wrapper. The Mac flow is identical but targets the macOS inflight version:

```typescript
// scripts/iap-attach-mac.ts
import { chromium } from "playwright";

const APP_ID = "6759594513";
const VERSION = "6.0.0";
const PLATFORM = "macos";

async function main() {
  const browser = await chromium.launch({ headless: false });
  const ctx = await browser.newContext();
  const page = await ctx.newPage();

  // Log in (interactive 2FA — script pauses for the code)
  await page.goto("https://appstoreconnect.apple.com/login");
  // ... user enters credentials + 2FA ...

  // Navigate to the macOS inflight version
  await page.goto(`https://appstoreconnect.apple.com/apps/${APP_ID}/distribution/${PLATFORM}/version/inflight`);

  // Wait for the IAP attach section to appear (it's visible only when the
  // version is in PREPARE_FOR_SUBMISSION — Task 9's submit:false flow).
  await page.waitForSelector("text=App 內購買項目和訂閱項目");

  // Click "Select In-App Purchases"
  await page.click("button:has-text('選取項目')");

  // Check the 3 tip jar IAPs (matches v5.3.2 IDs)
  await page.check("text=tip.small");
  await page.check("text=tip.medium");
  await page.check("text=tip.large");

  // Save
  await page.click("button:has-text('完成')");

  // Optionally: click "提交以供審查" to finalize
  // await page.click("button:has-text('提交以供審查')");

  await browser.close();
}
main();
```

(If a more refined existing script is present in the repo, reuse + adapt.)

- [ ] **Step 2: Run**

```bash
npm install playwright
npx playwright install chromium
npx tsx scripts/iap-attach-mac.ts
```

Manually complete the 2FA when prompted; verify IAPs are checked in the UI.

- [ ] **Step 3: Verify attachment**

Refresh the ASC inflight page; should show 3 IAPs attached to v6.0.0 (macOS).

---

## Task 11: Submit for review

**Files:** (none — runs `fastlane submit_mac_only`)

- [ ] **Step 1: Verify IAPs are attached**

Before submitting, confirm Task 10 actually attached the 3 tip-jar IAPs to the inflight version. Open `https://appstoreconnect.apple.com/apps/6759594513/distribution/macos/version/inflight` and verify the `App 內購買項目和訂閱項目` section lists tip.small / tip.medium / tip.large. If missing, ASC rejects the submission with "no IAP attached" — re-run Task 10 before proceeding.

- [ ] **Step 2: Run submit_mac_only**

```bash
fastlane submit_mac_only version:6.0.0 build:1
```

Or via ASC web UI: open v6.0.0 macOS inflight → "提交以供審查".

- [ ] **Step 3: Verify**

```bash
fastlane check_status_mac
```

Expected: v6.0.0 macOS in `WAITING_FOR_REVIEW`. iOS PeerDrop v6.0.0 from Task 9a should already be in `WAITING_FOR_REVIEW` from earlier in the day.

- [ ] **Step 4: Apple review buffer**

1–2 weeks. Monitor via `fastlane check_status_mac`. Common rejection vectors:
- Sandbox entitlement justification (covered in reviewer notes)
- Network usage description (covered in Info.plist)
- IAP screenshot ≠ 1024×1024 (covered in `feedback-asc-iap-quirks`)
- Self-drawn call panel (low risk per FaceTime/Slack/Discord precedent — flagged in spec §M4 risk register)

### Note on release strategy

Both `release` (iOS) and `release_mac` lanes default to `automatic_release: false` per the v5.4 / v5.3.2 patterns. After Apple approves, the build lands in `PENDING_DEVELOPER_RELEASE` and needs `fastlane release_now` (iOS) or its Mac equivalent to flip to READY_FOR_SALE.

First-Mac-ship caution: do NOT enable phased rollout for v6.0.0. The current iOS `release` lane has `phased_release: false` and the same default for Mac is correct — we want manual control over the initial Mac release given:
- This is the first Mac binary; sandbox surprises only surface in shipped builds.
- Spec §M4 risk register flags "Apple rejects self-drawn call panel" — low risk, but if it does land in production with a latent issue we want immediate rollback control rather than a partial-userbase exposure window.

Phased rollout becomes the default starting with v6.1.

---

## Task 11.5: MAS-install smoke check

**Files:** (none — manual)

After v6.0.0 is `READY_FOR_SALE` and you've flipped via `release_now`, install the **App Store version** (not the TestFlight build) on a clean Mac. App-Store-distributed sandboxed binaries can hit entitlement surprises that don't surface in dev / TestFlight builds.

- [ ] **Step 1: Wait for App Store propagation**

After `release_now`, allow ~30 min for the binary to reach the user-facing App Store. Verify by searching "PeerDrop" on App Store on a clean Mac.

- [ ] **Step 2: Install from App Store**

Download from App Store (NOT TestFlight). Launch. The system should prompt for microphone permission on first voice-call attempt.

- [ ] **Step 3: Run the manual smoke matrix from `docs/release/release-runbook.md`**

Specifically the M3 voice-calling matrix (7 rows) plus:
- [ ] BLE discovery works (potential `NSBluetoothAlwaysUsageDescription` requirement — missing this on a MAS build can fail silently)
- [ ] Bonjour discovery works (`com.apple.developer.networking.multicast` should cover this but verify)
- [ ] APNs push wakes the app from terminated state (needs `aps-environment = production`, NOT development — Task 4's reviewer notes already flag this)

- [ ] **Step 4: If failures surface**

File a v6.0.1 hotfix in `docs/release/v6.0.1-reviewer-notes.md`, bump `MARKETING_VERSION`, re-run `release_mac`. The MAS-install smoke check exists precisely to catch these BEFORE end users start downloading.

---

## Task 12: Release runbook update + memory + tag

**Files:**
- Modify: `docs/release/release-runbook.md` — Mac release lane usage section
- Auto-memory: `project-macos-port.md` + `MEMORY.md` — M4 status

- [ ] **Step 1: Runbook section**

Append "Mac App Store release" section to `docs/release/release-runbook.md` with:
- `fastlane release_mac` usage (`submit:false` for IAP-attach window)
- Playwright IAP-attach script invocation
- `submit_mac_only` for final submit
- Common rejection vectors + how to address
- ASC platform enablement (one-time)

- [ ] **Step 2: Auto-memory**

After v6.0.0 is `WAITING_FOR_REVIEW`, update memory:
- M4 ✅ shipped
- M0–M4 sequence complete
- Tag `m4-mas-submission-prep`

- [ ] **Step 3: Tag + push**

```bash
git tag -a m4-mas-submission-prep -m "M4 done: PeerDrop for Mac v6.0.0 submitted to MAS — first Mac binary WAITING_FOR_REVIEW. iOS v6.0.0 SPM rebuild submitted parallel."
git push origin m4-mas-submission-prep
```

---

## Done

After M4: **first Mac binary in Apple review queue**, iOS v6.0.0 SPM rebuild in parallel review. Both target same-day approval window. M0–M4 sequence complete.

**Next milestones (post-MAS approval):**
- Phased rollout monitoring
- v6.0.1 hotfixes if review surfaces issues
- v6.1 feature work — first Mac-led feature (e.g. Mac-only Finder integration, drag-from-Mail composer)

## Open architectural questions

1. **Snapshot resolution strategy** — single high-DPI capture and downsample, OR multiple Snapfile runs at different resolutions?
2. **TestFlight Mac eligibility** — does PeerDrop currently use TestFlight for iOS? If yes, parallel Mac TF beta; if no, internal-only and skip TF promo.
3. **IAP per-platform** — does the existing tip jar IAP work on Mac without re-creation, or does ASC require Mac-specific SKU? `feedback-asc-iap-quirks` notes only iOS; check ASC docs.
4. **Phased rollout** — current `release` lane has `phased_release: false`. Same for Mac? Spec §M4 risk register suggests staggered iOS → Mac release.
5. **Universal Purchase** — does ASC offer iOS↔Mac universal purchase for v6.0.0? If yes, users who paid the iOS tip jar get Mac for free. Verify policy.

## Estimated subagent dispatches

- Task 1: 1 implementer + 1 reviewer (large refactor — multiple files)
- Task 5: 1 implementer + 1 reviewer (fastlane lane)
- Task 6: 1 implementer + 1 reviewer (UI test target + Snapfile)
- Task 7: 1 implementer (translation work; no quality review needed beyond proofreading)
- Tasks 2/3/4/9/10/11: human-driven; no subagents

Total: ~4 subagent rounds. Most of M4 is human / manual / ASC-portal work.
