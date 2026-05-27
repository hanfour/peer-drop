# M2 — macOS UI Shell Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a `PeerDropApp-macOS` application target consuming the same `PeerDropKit` Swift Package that the iOS app uses. Implement the SwiftUI shell — `NavigationSplitView` main window, `MenuBarExtra` status item, `NSApplicationDelegate` (Dock drop, reopen, terminate-flush), menu commands, multi-window strategy (per-peer chat windows), keyboard shortcuts, drag-and-drop, light/dark theming. Voice UI stays hidden (M3 ships it). After M2 merges, both `.app` bundles build from one repo and an internal TestFlight Mac group can pair, chat, and transfer files with iOS users — including over the relay.

**Architecture:** New `PeerDropApp-macOS` SwiftUI app target. Reuses 90%+ of `PeerDrop/UI/` SwiftUI views (cross-platform — they already use Color/Image/Text/no UIKit). Diverges from iOS only at the chrome layer: top-level scene composition (NavigationSplitView vs TabView), AppDelegate (NSApplicationDelegate vs UIApplicationDelegate), and platform-specific affordances (NSOpenPanel vs UIDocumentPicker, NSPasteboard vs UIPasteboard — both already abstracted via `PeerDropPlatform`). Shared business logic via `PeerDropKit` (all 6 SPM products).

**Tech Stack:** Swift 5.9, macOS 14+ (Sonoma) — matches PeerDropKit's `.macOS(.v14)`. SwiftUI scene-based app lifecycle. XcodeGen 2.45.4. Builds: `xcodebuild build -scheme PeerDropMac -destination 'platform=macOS'`.

**Spec reference:** `docs/superpowers/specs/2026-05-24-macos-port-design.md` §4 (UI shell) + §5 (signing) + §6 (testing) + §7 M2 milestone (line 326). M3 (voice) and M4 (submission) are out of scope for M2 — they ship after.

**Predecessors:** M0 through M1d-5. Critical prerequisites:
- PR #54 (M1d-4 Transport) merged.
- PR #55 (M1d-5 Core) merged.
- All business logic accessible via `import PeerDropCore` / `import PeerDropPet` / etc.
- `BackgroundTaskHandling` Platform abstraction means `ConnectionManager` compiles on macOS (M1d-5 verified via `swift-build-macos` CI gate).

**Investigation findings (2026-05-27):**

### Current iOS UI structure (61 files, 10 subdirs)

```
PeerDrop/UI/
├── Chat/                      9 files (ChatView, ChatBubbleView, GroupChat, MediaPreview, etc.)
├── Components/                ~5 files (ConnectionStatusHeader, StatusBadge, etc.)
├── Connection/                6 files (ConnectedTab, ConnectionQR, ConsentSheet, ManualConnect, etc.)
├── Discovery/                 ~6 files (DiscoveryView, NearbyTab, PeerRow, GuidanceCard, etc.)
├── Library/                   ~6 files (LibraryTab, DeviceRecordRow, GroupRow, GroupDetail, etc.)
├── Relay/                     ~3 files (RelayConnectView, DevicePicker, etc.)
├── Security/                  ~4 files (SecurityDashboard, RemoteInviteView, InviteAcceptView, etc.)
├── Settings/                  ~6 files (TailnetPeersView, BackupRecordList, PushStatusRow, UserProfile, etc.)
├── Transfer/                  ~5 files (TransferProgress, FilePickerView, ClipboardShare, TransferHistory)
└── Voice/                     1 file (VoiceCallView — HIDDEN in M2)
```

Plus root-level: `ContentView.swift`, `SettingsView.swift`.

**Cross-platform-safe views:** Anything using only `Text`, `Image(systemName:)`, `Button`, `VStack`/`HStack`/`Form`, `@State`, `@EnvironmentObject`, `@AppStorage` works on macOS untouched. Most of UI/Chat, UI/Components, UI/Discovery, UI/Library, UI/Security, UI/Settings, UI/Transfer (except `UIDocumentPicker` uses) fit this profile.

**iOS-specific UI that needs macOS equivalents:**
- `UIDocumentPicker` in `FilePickerView` → `NSOpenPanel` (already abstracted? verify in audit)
- `UIImagePickerController` in `MediaPreviewView` / `ChatView` → `NSOpenPanel` filtered by image type
- `UIActivityViewController` (share sheet) → `NSSharingServicePicker`
- `UIApplication.shared.open(_:)` for external URLs → `NSWorkspace.shared.open(_:)`
- iOS `TabView` (in `ContentView.swift`) → macOS `NavigationSplitView` (we write a new `MacContentView`)

### Existing PeerDropPlatform abstractions covering iOS-vs-macOS

After M0/M1a/M1b/M1d-3a, the following Platform protocols already exist:
- `CallProvider` (iOS: CallKitManager; macOS M3: custom NSWindow)
- `AudioSessionConfiguring` (iOS: UIKitAudioSession; macOS: noop or AVAudioSession-mac)
- `HapticFeedback` (iOS: UIKitHapticFeedback; macOS: noop or NSSound)
- `PlatformPasteboard` (iOS: UIPasteboard; macOS: needs `NSPasteboardAdapter` in M2)
- `DeviceNameProvider` (iOS: UIDevice; macOS: needs `Host.current()` adapter in M2)
- `SystemInfoProvider` (iOS: UIDevice; macOS: needs adapter)
- `RemoteNotificationRegistering` (iOS: UIApplication; macOS: NSApplication adapter — but APNs for macOS is M3 territory)
- `PlatformGraphicsRenderer` (iOS: UIGraphicsImageRenderer; macOS: NSGraphicsContext adapter via M1a's PlatformGraphicsContext helper)
- `BackgroundTaskHandling` (iOS: UIKitBackgroundTaskHandler; macOS: NoOpBackgroundTaskHandler — M1d-5)

**M2 fills the macOS adapter side** for: PlatformPasteboard, DeviceNameProvider, SystemInfoProvider. (PlatformGraphicsRenderer is already cross-platform from M1a per `PlatformGraphicsContext`.)

### project.yml current state (post-M1d-5)

- `deploymentTarget: iOS: "16.0"` — needs `macOS: "14.0"` added
- 5 targets: PeerDrop (iOS app), PeerDropTests, PeerDropUITests, PeerDropWidget. None macOS.
- App target uses `- package: PeerDropKit` for all 6 products.
- After M1d-5 Task 10: no direct WebRTC/ZIPFoundation refs (both transitive via PeerDropKit).

### What NOT to do in M2

Per spec line 326: "Voice UI hidden." Don't wire up VoiceCallView on macOS. The button stub can exist but disabled/hidden. M3 ships voice.

Don't add APNs registration on macOS (M3 territory). The `RemoteNotificationRegistering` macOS adapter can be a no-op.

Don't auto-launch / login-item / Sparkle. App Store distribution doesn't allow auto-launch via Login Items API; Sparkle is for direct distribution. M2 ships through Mac App Store only.

---

## File Structure

**New target dir** (sibling of `PeerDrop/`):
```
PeerDropMac/
├── App/
│   ├── PeerDropMacApp.swift              # @main entry, scenes
│   ├── MacAppDelegate.swift              # NSApplicationDelegate
│   ├── Info.plist                        # macOS bundle metadata
│   ├── PeerDrop-Mac.entitlements         # sandbox, networking, file access
│   └── Assets.xcassets                   # AppIcon-macOS variants (M4 fills full set)
├── Views/
│   ├── MacContentView.swift              # Root NavigationSplitView (replaces iOS ContentView)
│   ├── MacSidebar.swift                  # Sidebar list (Nearby/Trusted/Relay/Pet)
│   ├── MacDetailRouter.swift             # Path-based navigation in detail pane
│   ├── MacChatWindow.swift               # Standalone chat window (one per peer)
│   ├── MacSettingsView.swift             # Settings scene (subset of iOS SettingsView)
│   ├── PeerDropCommands.swift            # @CommandsBuilder menu items
│   ├── MenuBarContent.swift              # MenuBarExtra popover body
│   └── MenuBarStatusIcon.swift           # Status icon (state-driven SF Symbol)
├── Adapters/
│   ├── NSPasteboardAdapter.swift         # PlatformPasteboard for macOS
│   ├── HostDeviceNameProvider.swift      # DeviceNameProvider for macOS via Host.current()
│   ├── MacSystemInfoProvider.swift       # SystemInfoProvider for macOS
│   └── MacPlatformDependencies.swift     # Wires the above
└── DragAndDrop/
    ├── MacDropHandler.swift              # Shared drop logic (Dock/main/menu bar)
    └── DropOverlay.swift                 # Visual overlay during drag-over
```

**Modify:**
- `project.yml` — add `macOS: "14.0"` to deploymentTarget; add `PeerDropMac` target; register Mac entitlements
- `PeerDropKit/Sources/PeerDropPlatform/iOS/` siblings — possibly rename `iOS/` to a more neutral location if M2 audit finds macOS-specific files growing too large there. (Decision deferred until Task 6.)

**Don't touch (much):**
- `PeerDrop/UI/` — most files reuse from macOS via cross-target source sharing in project.yml (the new PeerDropMac target includes `PeerDrop/UI/**` as sources, with macOS-incompatible files excluded). Goal: zero source-code duplication for Views.
- `PeerDrop/Core/` — gone (M1d-5 moved everything to PeerDropKit).

---

## Task 1: Pre-M2 audit

**Files:** (analysis only, no commits)

Goal: verify the prerequisites + survey which UI files are cross-platform safe.

- [ ] **Step 1: Verify M1 train merged**

```bash
git log --oneline main | head -5   # confirm M1d-4 + M1d-5 commits present
gh pr view 54 --json state -q .state   # expect MERGED
gh pr view 55 --json state -q .state   # expect MERGED
```

If either PR is not merged, **STOP and escalate**. M2 depends on PeerDropCore being built.

- [ ] **Step 2: Verify swift build succeeds for macOS**

```bash
cd PeerDropKit && swift build 2>&1 | tail -3 && cd ..
```

Expected: `Build complete!`. This confirms `BackgroundTaskHandling`, `NWError.wifiAware` fix, and all 6 modules compile on the macOS host toolchain.

- [ ] **Step 3: Audit UI files for cross-platform compatibility**

```bash
# Check each UI file for iOS-only types
for f in PeerDrop/UI/**/*.swift PeerDrop/UI/*.swift; do
    if grep -l "UIApplication\|UIDocumentPicker\|UIImagePicker\|UIActivityView\|@UIApplicationDelegateAdaptor\|UIViewControllerRepresentable" "$f" 2>/dev/null; then
        echo "iOS-only: $f"
    fi
done
```

Report each iOS-only view. Expected ~5-8 files. Decide for each:
- **Replace with macOS equivalent** (e.g. `FilePickerView` → use `.fileImporter`/`NSOpenPanel`)
- **Wrap in `#if os(iOS)`** (Voice, push-notification rows)
- **Refactor to use Platform abstraction** if pattern repeats

- [ ] **Step 4: Survey iOS `ContentView.swift` for navigation structure**

Read `PeerDrop/UI/ContentView.swift`. Identify the tab structure (Discovery / Library / Pet / Settings). Map each tab to a sidebar item in macOS. Estimate per-tab view reuse cost.

- [ ] **Step 5: Confirm spec §4 components map cleanly**

Cross-check the spec's stated UI components against the project's existing views:
- Spec §4 mentions Pet sprite in menu bar — `PeerDropPet`'s renderer should produce CGImage that NSImage wraps. Verify.
- Spec §4 mentions URL scheme `peerdrop://chat/<peerID>` — needs Info.plist `CFBundleURLTypes` registration in Task 4. Note for later.
- Spec §4 keyboard shortcuts (⌘1, ⌘N, ⌘O, etc.) — these are SwiftUI `.keyboardShortcut` modifiers in PeerDropCommands. Standard.

- [ ] **Step 6: Report findings**

```
## M2 audit (2026-05-27)

### Prerequisites
- M1d-4 merged: YES/NO
- M1d-5 merged: YES/NO
- PeerDropKit swift build clean: YES/NO

### iOS-only UI files
- <file:line list>
  Each annotated with: REPLACE / GATE / REFACTOR

### Tab → sidebar mapping
- iOS Discovery tab → macOS Sidebar item "Nearby"
- iOS Library tab → macOS Sidebar item "Trusted"
- iOS Settings tab → macOS Settings scene (separate Settings { ... } scene)
- iOS Pet section → macOS Sidebar item "Pet"

### Open questions for the human
- <any decisions the plan didn't resolve>
```

**No commits in Task 1.** Output is the audit report.

---

## Task 2: Add macOS target scaffold to project.yml

**Files:** Modify `project.yml`; create `PeerDropMac/App/Info.plist`, `PeerDropMac/App/PeerDrop-Mac.entitlements`.

- [ ] **Step 1: Add macOS deployment target**

In `project.yml` under `options.deploymentTarget`:

```yaml
options:
  deploymentTarget:
    iOS: "16.0"
    macOS: "14.0"
```

- [ ] **Step 2: Add `PeerDropMac` target block**

After the iOS `PeerDrop:` target block, add (place AFTER the iOS target to keep diff localized):

```yaml
  PeerDropMac:
    type: application
    platform: macOS
    sources:
      - path: PeerDropMac
      # Reuse cross-platform views from the iOS UI tree.
      # Files that touch UIApplication / UIDocumentPicker etc. are
      # gated via `#if canImport(UIKit)` inside themselves and stay
      # macOS-compatible. The few that aren't get explicit excludes
      # listed below (filled in per Task 1 audit).
      - path: PeerDrop/UI
        excludes:
          - "Voice/**"          # M3 ships voice; M2 hides
          # (additional iOS-only files per audit)
    dependencies:
      - package: PeerDropKit
        product: PeerDropPlatform
      - package: PeerDropKit
        product: PeerDropCore
      - package: PeerDropKit
        product: PeerDropTransport
      - package: PeerDropKit
        product: PeerDropSecurity
      - package: PeerDropKit
        product: PeerDropProtocol
      - package: PeerDropKit
        product: PeerDropPet
    settings:
      base:
        INFOPLIST_FILE: PeerDropMac/App/Info.plist
        PRODUCT_BUNDLE_IDENTIFIER: com.hanfour.peerdrop.mac
        DEVELOPMENT_TEAM: UK48R5KWLV
        CODE_SIGN_STYLE: Automatic
        CODE_SIGN_ENTITLEMENTS: PeerDropMac/App/PeerDrop-Mac.entitlements
        MARKETING_VERSION: "6.0.0"
        CURRENT_PROJECT_VERSION: "1"
        SWIFT_VERSION: "5.9"
        MACOSX_DEPLOYMENT_TARGET: "14.0"
        SDKROOT: macosx
        ENABLE_HARDENED_RUNTIME: "YES"
        # App Sandbox is a HARD requirement for Mac App Store distribution.
        # The entitlements file declares the actual capabilities.
```

- [ ] **Step 3: Create `PeerDropMac/App/Info.plist`**

Minimal Mac app Info.plist. Include:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>PeerDrop</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$(MARKETING_VERSION)</string>
    <key>CFBundleVersion</key>
    <string>$(CURRENT_PROJECT_VERSION)</string>
    <key>LSMinimumSystemVersion</key>
    <string>$(MACOSX_DEPLOYMENT_TARGET)</string>
    <key>NSHumanReadableCopyright</key>
    <string>© 2026 Hanfour Huang. All rights reserved.</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <false/>
    </dict>
    <!-- URL scheme for peerdrop:// links from chat / share sheets -->
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>com.hanfour.peerdrop.mac.url</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>peerdrop</string>
            </array>
        </dict>
    </array>
    <!-- Localizations -->
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>zh-Hant</string>
        <string>zh-Hans</string>
        <string>ja</string>
        <string>ko</string>
    </array>
</dict>
</plist>
```

- [ ] **Step 4: Create `PeerDropMac/App/PeerDrop-Mac.entitlements`**

Mac App Store sandbox requirements:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Hard requirement for Mac App Store -->
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <!-- Networking: outbound for relay + worker, incoming for Bonjour discovery -->
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.network.server</key>
    <true/>
    <!-- File access: user-selected drops + Open dialog -->
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
    <!-- For inbox + history caches -->
    <key>com.apple.security.files.downloads.read-write</key>
    <true/>
    <!-- Bonjour services (matches iOS PeerDrop entitlements) -->
    <key>com.apple.security.bluetooth</key>
    <true/>
    <!-- Required for relay (TLS over WebSocket) -->
    <key>com.apple.developer.networking.multicast</key>
    <true/>
</dict>
</plist>
```

- [ ] **Step 5: Regenerate Xcode project + verify**

```bash
xcodegen generate 2>&1 | tail -3
ls PeerDrop.xcodeproj/  # confirm regenerated
```

Verify Xcode project has the new `PeerDropMac` target (open in Xcode briefly, or `xcodebuild -list` and confirm `PeerDropMac` appears).

```bash
xcodebuild -list 2>&1 | head -20
```

- [ ] **Step 6: Build the (empty) macOS target — expect failure**

```bash
xcodebuild build -scheme PeerDropMac -destination 'platform=macOS' 2>&1 | tail -5
```

Expected: failure because no `@main` entry point exists yet (Task 3 adds it). The point is to confirm the scaffolding compiles project.yml correctly.

- [ ] **Step 7: Commit scaffolding**

```bash
git add project.yml PeerDropMac/ PeerDrop.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
feat(m2): scaffold PeerDropMac target in project.yml

Adds the macOS application target alongside the existing iOS target.
Reuses every PeerDropKit product directly (cross-platform). Reuses
PeerDrop/UI/ source tree as a `path:` source pool (cross-platform
SwiftUI Views compile on both targets; iOS-only Views excluded
per audit list).

New files:
  PeerDropMac/App/Info.plist                       (macOS bundle, peerdrop:// URL scheme)
  PeerDropMac/App/PeerDrop-Mac.entitlements        (Mac App Store sandbox + networking)

project.yml gains:
  deploymentTarget.macOS = 14.0
  PeerDropMac target (com.hanfour.peerdrop.mac, MARKETING_VERSION = 6.0.0)

Build does NOT pass yet — @main entry point arrives in Task 3.
Subsequent M2 tasks build out the SwiftUI shell + AppDelegate.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Mac AppDelegate + Entry point

**Files:**
- Create: `PeerDropMac/App/MacAppDelegate.swift`
- Create: `PeerDropMac/App/PeerDropMacApp.swift`

- [ ] **Step 1: Create `MacAppDelegate.swift`**

```swift
import AppKit
import SwiftUI
import os
import PeerDropCore
import PeerDropPlatform

@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private let logger = Logger(subsystem: "com.hanfour.peerdrop.mac", category: "AppDelegate")

    /// Visibility of the menu bar item — toggled by the View menu command.
    @Published var menuBarVisible: Bool = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("macOS app finished launching")
        // Register the macOS-specific PlatformDependencies adapters.
        // (Task 6 wires this up via MacPlatformDependencies.register())
        MacPlatformDependencies.register()
    }

    /// Finder drop / open-with handler. Files arrive via NSURL array.
    func application(_ application: NSApplication, open urls: [URL]) {
        logger.info("Open URLs: \(urls.map(\.lastPathComponent).joined(separator: ", "))")
        // Forward to ConnectionManager — same drop-handling path as the
        // main-window drop target. The peer-selection sheet ALWAYS appears
        // before send (App Review compliance).
        Task { @MainActor in
            await ConnectionManager.shared.handleIncomingFiles(urls: urls)
        }
    }

    /// Dock click when the main window is closed should reopen it.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            // No visible windows — present the main scene.
            NSApp.windows
                .first(where: { $0.identifier?.rawValue == "PeerDropMain" })?
                .makeKeyAndOrderFront(nil)
        }
        return true
    }

    /// On quit, flush any pending persists (debounced chat saves, etc.).
    func applicationWillTerminate(_ notification: Notification) {
        logger.info("Terminating — flushing pending persists")
        ConnectionManager.shared.flushAllPendingPersists()
    }
}
```

Notes:
- `ConnectionManager.handleIncomingFiles(urls:)` and `flushAllPendingPersists()` must already be public (they are, after M1d-5 marked Core public). If a method is missing, surface it in Task 8 build verify.
- Window identifier `"PeerDropMain"` is set in Task 5 when the WindowGroup is defined.

- [ ] **Step 2: Create `PeerDropMacApp.swift` entry point**

```swift
import SwiftUI
import PeerDropCore
import PeerDropPlatform

@main
struct PeerDropMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) var appDelegate

    @StateObject private var connectionManager = ConnectionManager.shared

    var body: some Scene {
        // Main window: discovery + sidebar navigation (filled in Task 5).
        WindowGroup("PeerDrop", id: "PeerDropMain") {
            MacContentView()
                .environmentObject(connectionManager)
                .environmentObject(appDelegate)
                .frame(minWidth: 720, minHeight: 480)
        }
        .commands { PeerDropCommands() }

        // Settings scene (⌘,)
        Settings {
            MacSettingsView()
                .environmentObject(connectionManager)
                .frame(width: 520, height: 360)
        }

        // Menu bar item — visibility bound to AppDelegate's @Published flag.
        MenuBarExtra(isInserted: $appDelegate.menuBarVisible) {
            MenuBarContent()
                .environmentObject(connectionManager)
                .frame(width: 360, height: 500)
        } label: {
            MenuBarStatusIcon(state: connectionManager.aggregateState)
        }
        .menuBarExtraStyle(.window)
    }
}
```

Notes:
- `MacContentView`, `MacSettingsView`, `MenuBarContent`, `MenuBarStatusIcon`, `PeerDropCommands` are forward references — they're stubbed in Tasks 4-7 and 10-11. For Task 3 to compile, create empty stub Views for each:

- [ ] **Step 3: Create empty Mac View stubs**

Create these as one-liner placeholder files (each in `PeerDropMac/Views/`):

```swift
// PeerDropMac/Views/MacContentView.swift
import SwiftUI
struct MacContentView: View {
    var body: some View {
        Text("PeerDrop for Mac — TODO")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// PeerDropMac/Views/MacSettingsView.swift
import SwiftUI
struct MacSettingsView: View {
    var body: some View {
        Text("Settings — TODO")
    }
}

// PeerDropMac/Views/MenuBarContent.swift
import SwiftUI
struct MenuBarContent: View {
    var body: some View {
        Text("Menu Bar — TODO")
            .frame(width: 360, height: 500)
    }
}

// PeerDropMac/Views/MenuBarStatusIcon.swift
import SwiftUI
import PeerDropCore
struct MenuBarStatusIcon: View {
    let state: ConnectionState
    var body: some View {
        Image(systemName: "circle.dotted")
    }
}

// PeerDropMac/Views/PeerDropCommands.swift
import SwiftUI
struct PeerDropCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) { /* TODO Task 11 */ }
    }
}
```

- [ ] **Step 4: Create empty MacPlatformDependencies stub**

```swift
// PeerDropMac/Adapters/MacPlatformDependencies.swift
import Foundation

enum MacPlatformDependencies {
    static func register() {
        // TODO Task 6 — register macOS adapters (NSPasteboard, Host name, etc.)
    }
}
```

- [ ] **Step 5: Build verify**

```bash
xcodegen generate 2>&1 | tail -3
xcodebuild build -scheme PeerDropMac -destination 'platform=macOS' 2>&1 | grep -E "error:" | head -10
```

Iterate on errors. Most likely: a Core symbol that's public on iOS but the macOS target imports a `#if os(iOS)` gated property accidentally. Triage via re-publicizing or guarding.

Expected once clean: `BUILD SUCCEEDED`. The app launches to a placeholder window saying "PeerDrop for Mac — TODO".

- [ ] **Step 6: Manual smoke test**

```bash
xcodebuild -scheme PeerDropMac -destination 'platform=macOS' build && open ~/Library/Developer/Xcode/DerivedData/PeerDrop-*/Build/Products/Debug/PeerDropMac.app
```

Verify:
- App launches without crashing
- "PeerDrop for Mac — TODO" window appears
- Menu bar icon (default `circle.dotted`) shows up
- `⌘,` opens an empty Settings window

- [ ] **Step 7: Commit**

```bash
git add PeerDropMac/ PeerDrop.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
feat(m2): macOS AppDelegate + SwiftUI entry point (placeholder views)

Wires up:
  - PeerDropMacApp @main with WindowGroup/Settings/MenuBarExtra scenes
  - MacAppDelegate (NSApplicationDelegate) handling open/reopen/terminate
  - MacAppDelegate.applicationWillTerminate flushes ConnectionManager
    pending persists (same pattern as iOS AppDelegate)
  - Placeholder views for MacContentView / MacSettingsView /
    MenuBarContent / MenuBarStatusIcon / PeerDropCommands so the
    target compiles; real content arrives in Tasks 4-7 and 10-11
  - Empty MacPlatformDependencies.register() stub; Task 6 fills it

macOS build is now green and the .app launches to a placeholder
window. Menu bar icon (circle.dotted) and ⌘, Settings work end-to-end.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: macOS Platform adapters (PlatformDependencies wiring)

**Files:**
- Create: `PeerDropMac/Adapters/NSPasteboardAdapter.swift`
- Create: `PeerDropMac/Adapters/HostDeviceNameProvider.swift`
- Create: `PeerDropMac/Adapters/MacSystemInfoProvider.swift`
- Modify: `PeerDropMac/Adapters/MacPlatformDependencies.swift` (fill in `register()`)

This task fills the macOS side of three PeerDropPlatform protocols that didn't get macOS adapters in M1d-3a (only iOS adapters existed).

- [ ] **Step 1: NSPasteboardAdapter**

Look at the protocol surface in `PeerDropKit/Sources/PeerDropPlatform/PlatformPasteboard.swift`. Implement:

```swift
import AppKit
import PeerDropPlatform

final class NSPasteboardAdapter: PlatformPasteboard {
    func copy(string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }

    func string() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    func copy(image data: Data) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let img = NSImage(data: data) {
            pb.writeObjects([img])
        }
    }

    func imageData() -> Data? {
        guard let img = NSPasteboard.general.readObjects(forClasses: [NSImage.self])?.first as? NSImage,
              let tiff = img.tiffRepresentation else {
            return nil
        }
        return tiff
    }
}
```

(Method names must match the existing protocol — adapt if signatures differ.)

- [ ] **Step 2: HostDeviceNameProvider**

```swift
import AppKit
import PeerDropPlatform

final class HostDeviceNameProvider: DeviceNameProvider {
    /// Returns the computer name (System Settings > General > About > Name)
    /// — matches the discoverable name shown on iOS via UIDevice.current.name.
    var currentName: String {
        Host.current().localizedName ?? Host.current().name ?? "Mac"
    }
}
```

- [ ] **Step 3: MacSystemInfoProvider**

```swift
import AppKit
import PeerDropPlatform

final class MacSystemInfoProvider: SystemInfoProvider {
    var systemVersion: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }
    var modelIdentifier: String {
        // sysctl-based model identifier (e.g. "Mac14,12"). Used for telemetry.
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }
    // Add other SystemInfoProvider members per the protocol's actual surface.
}
```

- [ ] **Step 4: Wire register()**

In `MacPlatformDependencies.swift`:

```swift
import Foundation
import PeerDropPlatform

@MainActor
enum MacPlatformDependencies {
    /// Called from MacAppDelegate.applicationDidFinishLaunching.
    /// Registers macOS-specific adapters into the PlatformDependencies registry.
    /// iOS-specific adapters (UIKit*) are guarded by `#if os(iOS)` inside the
    /// registry and never reach the macOS build.
    static func register() {
        PlatformDependencies.shared.pasteboard = { NSPasteboardAdapter() }
        PlatformDependencies.shared.deviceName = { HostDeviceNameProvider() }
        PlatformDependencies.shared.systemInfo = { MacSystemInfoProvider() }
        // BackgroundTaskHandling defaults to NoOpBackgroundTaskHandler on
        // macOS via PlatformDependencies.makeBackgroundTaskHandler — no
        // explicit registration needed.
        // CallProvider defaults to NoOpCallProvider on macOS until M3
        // ships the custom NSWindow-based panel.
    }
}
```

- [ ] **Step 5: Build verify**

```bash
xcodebuild build -scheme PeerDropMac -destination 'platform=macOS' 2>&1 | tail -3
```

Expected: `BUILD SUCCEEDED`. The adapters are wired but no UI consumes them yet.

- [ ] **Step 6: Commit**

```bash
git add PeerDropMac/Adapters/
git commit -m "$(cat <<'EOF'
feat(m2): macOS adapters for Platform protocols (Pasteboard, Host, SystemInfo)

Fills the macOS side of three PeerDropPlatform protocols that M1d-3a
left as iOS-only:
  - NSPasteboardAdapter (PlatformPasteboard via NSPasteboard.general)
  - HostDeviceNameProvider (DeviceNameProvider via Host.current().localizedName)
  - MacSystemInfoProvider (SystemInfoProvider via ProcessInfo + sysctl)

Registered in MacAppDelegate.applicationDidFinishLaunching via
MacPlatformDependencies.register(). BackgroundTaskHandling +
CallProvider already default to NoOpBackgroundTaskHandler /
NoOpCallProvider on macOS — no explicit registration needed.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: NavigationSplitView main window

**Files:**
- Modify: `PeerDropMac/Views/MacContentView.swift` (replace placeholder)
- Create: `PeerDropMac/Views/MacSidebar.swift`
- Create: `PeerDropMac/Views/MacDetailRouter.swift`

- [ ] **Step 1: Define section model**

In `MacSidebar.swift`:

```swift
import SwiftUI

enum MacSidebarSection: String, Hashable, CaseIterable, Identifiable {
    case nearby
    case trusted
    case relay
    case pet

    var id: Self { self }

    var localizedName: String {
        switch self {
        case .nearby:  return NSLocalizedString("Nearby", comment: "")
        case .trusted: return NSLocalizedString("Trusted", comment: "")
        case .relay:   return NSLocalizedString("Relay", comment: "")
        case .pet:     return NSLocalizedString("Pet", comment: "")
        }
    }

    var icon: String {
        switch self {
        case .nearby:  return "wifi"
        case .trusted: return "checkmark.shield"
        case .relay:   return "network"
        case .pet:     return "pawprint"
        }
    }
}

struct MacSidebar: View {
    @Binding var selection: MacSidebarSection?

    var body: some View {
        List(MacSidebarSection.allCases, selection: $selection) { section in
            Label(section.localizedName, systemImage: section.icon)
                .tag(section)
        }
        .listStyle(.sidebar)
        .navigationTitle("PeerDrop")
    }
}
```

- [ ] **Step 2: Detail router**

```swift
// PeerDropMac/Views/MacDetailRouter.swift
import SwiftUI
import PeerDropCore

struct MacDetailRouter: View {
    let section: MacSidebarSection?
    @EnvironmentObject var connectionManager: ConnectionManager

    var body: some View {
        switch section {
        case .nearby:
            NearbyTab()    // reused from PeerDrop/UI/Discovery/NearbyTab.swift
        case .trusted:
            LibraryTab()   // reused from PeerDrop/UI/Library/LibraryTab.swift
        case .relay:
            RelayConnectView()   // reused from PeerDrop/UI/Relay/RelayConnectView.swift
        case .pet:
            PetSectionView()     // see Task 9
        case .none:
            ContentUnavailableView(
                "Choose a section",
                systemImage: "sidebar.left",
                description: Text("Pick Nearby, Trusted, Relay, or Pet from the sidebar.")
            )
        }
    }
}
```

If `NearbyTab` / `LibraryTab` / `RelayConnectView` have iOS-specific imports or `@EnvironmentObject` requirements that don't fit on macOS, the audit (Task 1) flagged them. Either wrap reuse in a thin `Mac*ViewWrapper` shim that maps env objects, or replace with macOS variants — but the goal is reuse.

- [ ] **Step 3: MacContentView with NavigationSplitView**

```swift
// PeerDropMac/Views/MacContentView.swift
import SwiftUI
import PeerDropCore

struct MacContentView: View {
    @State private var selection: MacSidebarSection? = .nearby
    @AppStorage("sidebar.width") private var sidebarWidth: Double = 220

    var body: some View {
        NavigationSplitView {
            MacSidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 180, ideal: sidebarWidth, max: 360)
        } detail: {
            MacDetailRouter(section: selection)
                .navigationSplitViewColumnWidth(min: 480, ideal: 600)
        }
        .navigationSplitViewStyle(.balanced)
    }
}
```

- [ ] **Step 4: Build + smoke-test**

```bash
xcodebuild build -scheme PeerDropMac -destination 'platform=macOS' 2>&1 | tail -3
```

If errors mention `NearbyTab` / `LibraryTab` etc. as not found, those views must be included in the macOS target's sources. Verify `project.yml`'s `PeerDropMac.sources` includes `PeerDrop/UI` (Task 2 Step 2).

If errors mention iOS-only types inside those views, the audit's exclude list (Task 2 Step 2) needs to grow. Add the offending file to `excludes:`, then build again.

Open the .app and verify the sidebar + detail split shows the 4 sections.

- [ ] **Step 5: Commit**

```bash
git add PeerDropMac/Views/
git commit -m "$(cat <<'EOF'
feat(m2): NavigationSplitView main window (sidebar + detail)

Replaces the Task 3 placeholder with a real NavigationSplitView:
  - Sidebar: 4 sections (Nearby / Trusted / Relay / Pet)
    using @AppStorage("sidebar.width") for width persistence per
    spec §4
  - Detail: routes via MacSidebarSection to existing UI views
    (NearbyTab, LibraryTab, RelayConnectView reused from PeerDrop/UI/)
  - Pet section: stub for Task 9

Voice section intentionally omitted in M2 (M3 ships it).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Replace iOS-only Views with macOS equivalents

**Files:** depends on Task 1 audit findings. Likely candidates:
- `PeerDrop/UI/Transfer/FilePickerView.swift` — uses `UIDocumentPicker`; on macOS use SwiftUI `.fileImporter(isPresented:allowedContentTypes:)`. Either refactor to be cross-platform via `#if os(iOS) UIDocumentPicker #else .fileImporter` OR create `PeerDropMac/Views/MacFilePickerView.swift` and exclude the iOS one in `project.yml`.
- `PeerDrop/UI/Chat/MediaPreviewView.swift` — possibly uses UIImagePickerController. Same pattern.

Prefer cross-platform refactor (touches one file) over duplicate macOS views (touches two files + exclude list).

- [ ] **Step 1: Refactor `FilePickerView` to cross-platform**

Read the existing file. If it wraps `UIDocumentPickerRepresentable`, replace the `UIViewControllerRepresentable` body with SwiftUI's `.fileImporter`. SwiftUI's `.fileImporter` exists since iOS 14 / macOS 11, so it works on both targets.

```swift
import SwiftUI
import UniformTypeIdentifiers

struct FilePickerView: View {
    @Binding var isPresented: Bool
    @Binding var selectedURLs: [URL]
    let allowedContentTypes: [UTType]
    let allowsMultipleSelection: Bool

    var body: some View {
        Color.clear   // anchor for .fileImporter
            .fileImporter(
                isPresented: $isPresented,
                allowedContentTypes: allowedContentTypes,
                allowsMultipleSelection: allowsMultipleSelection
            ) { result in
                switch result {
                case .success(let urls): selectedURLs = urls
                case .failure: break
                }
            }
    }
}
```

If the existing API surface is different (e.g. the view takes a completion handler), preserve the call site contract and adapt the body.

- [ ] **Step 2: Test the refactored view on iOS first**

```bash
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' 2>&1 | tail -3
xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' 2>&1 | grep "Executed " | tail -2
```

Expected: 635 tests still pass. No regression on iOS.

- [ ] **Step 3: Build on macOS**

```bash
xcodebuild build -scheme PeerDropMac -destination 'platform=macOS' 2>&1 | tail -3
```

Expected: `BUILD SUCCEEDED`. `FilePickerView` now compiles on both platforms.

Repeat Steps 1-3 for each iOS-only View identified in Task 1 audit. **If a view is too entangled with UIKit, create a Mac-specific replacement instead** and exclude the iOS one from the macOS target.

- [ ] **Step 4: Update `project.yml` excludes list as needed**

If any view ended up as macOS-specific replacement, add the original iOS file to the macOS target's `sources.path.excludes` list. Regenerate.

- [ ] **Step 5: Commit (one per view if needed, or combined)**

```bash
git add PeerDrop/UI/ PeerDropMac/ project.yml PeerDrop.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
refactor(m2): cross-platform N iOS-only Views for macOS reuse

Refactored these Views from UIKit-wrapped to SwiftUI-native so the
macOS target reuses them directly:
  - FilePickerView: UIDocumentPickerRepresentable → SwiftUI .fileImporter
  - <list each>

Each change is API-compatible — same Binding signatures, same
behavior on iOS (verified 635 iOS tests pass).

(For views too entangled with UIKit, dedicated PeerDropMac/Views/Mac<X>.swift
created instead; iOS originals excluded from PeerDropMac target sources.)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Per-peer Chat windows

**Files:**
- Create: `PeerDropMac/Views/MacChatWindow.swift`
- Modify: `PeerDropMac/App/PeerDropMacApp.swift` (add `Window(id: "chat-...", for: PeerIdentity.self)`)

Per spec §4 "Multi-window strategy", chat opens in its own Window. Pattern: SwiftUI's `WindowGroup(for: Value.self)` opens a new window per `peerID`, supports `openWindow(value:)` from any View.

- [ ] **Step 1: Define `MacChatWindow`**

```swift
import SwiftUI
import PeerDropCore
import PeerDropSecurity

struct MacChatWindow: View {
    let peerID: String
    @EnvironmentObject var connectionManager: ConnectionManager

    var body: some View {
        // Reuse iOS ChatView verbatim; ConnectionManager exposes the
        // ChatManager + message bindings. ChatView is cross-platform
        // (uses Text/Image/ScrollViewReader — no UIKit).
        ChatView(peerID: peerID)
            .frame(minWidth: 480, minHeight: 360)
            .navigationTitle(connectionManager.displayName(forPeerID: peerID) ?? "Chat")
    }
}
```

Adjust `displayName(forPeerID:)` to whatever API ConnectionManager actually exposes; add it as a public helper if missing.

- [ ] **Step 2: Register the Window scene in PeerDropMacApp**

In `PeerDropMacApp.swift`, after the main `WindowGroup`:

```swift
WindowGroup(id: "chat", for: String.self) { $peerID in
    if let peerID {
        MacChatWindow(peerID: peerID)
            .environmentObject(connectionManager)
    } else {
        Text("No peer selected")
    }
}
.keyboardShortcut("1", modifiers: .command)  // matches spec §4 Window menu
```

- [ ] **Step 3: Open chat windows from the detail pane**

In `MacDetailRouter.swift` or the NearbyTab itself, wire a row tap to `openWindow(id: "chat", value: peerID)`:

```swift
@Environment(\.openWindow) private var openWindow

// In a peer row's onTap or button action:
openWindow(id: "chat", value: peer.id)
```

If `NearbyTab` doesn't already have a tap-to-chat affordance on iOS (the iOS UX shows chat in the same tab), add a macOS-only variant or use SwiftUI's contextual menu (`.contextMenu`) for "Open Chat in New Window".

- [ ] **Step 4: Build + manual test**

```bash
xcodebuild build -scheme PeerDropMac -destination 'platform=macOS' 2>&1 | tail -3
```

Launch the .app, pair with another device (or use Screenshot Mode if available — check `ScreenshotModeProvider`), and verify clicking a peer opens a new chat window with the correct title.

- [ ] **Step 5: Commit**

```bash
git add PeerDropMac/
git commit -m "$(cat <<'EOF'
feat(m2): per-peer chat windows on macOS

Chat opens in a standalone window (`WindowGroup(for: String.self)`) so
multiple conversations can live side-by-side — matches spec §4
multi-window strategy. ⌘1 keyboard shortcut focuses the most-recent
chat window.

Reuses PeerDrop/UI/Chat/ChatView verbatim; the only macOS-specific
piece is the MacChatWindow wrapper that adds a minimum size +
navigation title. Pulls peer's displayName via
ConnectionManager.displayName(forPeerID:).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: MenuBarExtra content

**Files:**
- Modify: `PeerDropMac/Views/MenuBarContent.swift` (replace placeholder)
- Modify: `PeerDropMac/Views/MenuBarStatusIcon.swift` (state-driven icon)

Per spec §4: ~360×500 popover with status header, peers list (with inline ⊕ Send), pending transfers, Pet mini-sprite, Open/Quit.

- [ ] **Step 1: MenuBarStatusIcon — state-driven SF Symbol**

```swift
import SwiftUI
import PeerDropCore

struct MenuBarStatusIcon: View {
    let state: ConnectionState
    var body: some View {
        Image(systemName: iconName)
            .accessibilityLabel(accessibilityLabel)
    }

    private var iconName: String {
        switch state {
        case .idle:        return "circle.dotted"
        case .scanning:    return "antenna.radiowaves.left.and.right"
        case .connecting:  return "arrow.triangle.2.circlepath"
        case .connected:   return "checkmark.circle.fill"
        case .voiceCall:   return "phone.fill"
        // Add others per actual ConnectionState cases
        @unknown default:  return "circle.dotted"
        }
    }

    private var accessibilityLabel: String {
        NSLocalizedString("PeerDrop status: \(state)", comment: "")
    }
}
```

- [ ] **Step 2: MenuBarContent — full popover**

```swift
import SwiftUI
import PeerDropCore
import PeerDropPet

struct MenuBarContent: View {
    @EnvironmentObject var connectionManager: ConnectionManager

    var body: some View {
        VStack(spacing: 0) {
            // Status header
            HStack {
                MenuBarStatusIcon(state: connectionManager.aggregateState)
                Text(statusText)
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            // Peers list with inline ⊕ Send
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(connectionManager.discoveredPeers) { peer in
                        MenuBarPeerRow(peer: peer)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 220)

            Divider()

            // Pending transfers (compact)
            if connectionManager.activeTransfers.isEmpty {
                Text("No active transfers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(connectionManager.activeTransfers) { transfer in
                    MenuBarTransferRow(transfer: transfer)
                }
            }

            Divider()

            // Pet mini-sprite (60x60 box, reuses PeerDropPet renderer)
            PetMiniSprite(genome: connectionManager.petGenome)
                .frame(width: 60, height: 60)
                .padding(.vertical, 6)

            Divider()

            // Open / Quit
            HStack {
                Button("Open PeerDrop") {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first(where: { $0.identifier?.rawValue == "PeerDropMain" })?
                        .makeKeyAndOrderFront(nil)
                }
                Spacer()
                Button("Quit") {
                    NSApp.terminate(nil)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
    }

    private var statusText: String {
        switch connectionManager.aggregateState {
        case .idle: return NSLocalizedString("Idle", comment: "")
        case .scanning: return NSLocalizedString("Scanning…", comment: "")
        case .connected: return NSLocalizedString("Connected", comment: "")
        default: return ""
        }
    }
}

// Helper row types — define inline or in separate files
struct MenuBarPeerRow: View { /* ... */ }
struct MenuBarTransferRow: View { /* ... */ }
struct PetMiniSprite: View { /* uses PeerDropPet renderer */ }
```

(API names like `connectionManager.discoveredPeers`, `.activeTransfers`, `.petGenome`, `displayName(forPeerID:)` are speculative — adapt to whatever ConnectionManager actually exposes. If a method is missing, surface it as public via a small targeted edit in PeerDropCore.)

- [ ] **Step 3: Build + smoke test**

Launch the .app, click the menu bar icon. Verify:
- Popover shows ~360×500
- Status header reflects current state
- Empty state for peers list
- Empty state for transfers ("No active transfers")
- Pet mini-sprite renders (or empty box if no pet)
- "Open PeerDrop" raises main window
- "Quit" terminates app

- [ ] **Step 4: Commit**

```bash
git add PeerDropMac/Views/
git commit -m "$(cat <<'EOF'
feat(m2): MenuBarExtra popover content

Status header + peers list + pending transfers + Pet mini-sprite +
Open/Quit. Matches spec §4 layout (~360×500). Pet sprite reuses
PeerDropPet renderer (same CGImage path as main window + iOS widget).

Status icon switches between idle/scanning/connecting/connected SF
Symbols based on ConnectionManager.aggregateState.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Pet section + sprite rendering

**Files:**
- Create: `PeerDropMac/Views/PetSectionView.swift`
- Verify: `PeerDropPet`'s renderer produces `CGImage` that NSImage wraps cleanly

- [ ] **Step 1: Test the Pet renderer on macOS**

Open the existing iOS Pet hub view in `PeerDrop/UI/`. If it uses `Image(uiImage:)`, that won't compile on macOS. Need to use the cross-platform `PlatformImage` typealias from M1a or convert explicitly.

If iOS uses `Image(uiImage: UIImage(cgImage: renderedCGImage))`, the macOS equivalent is `Image(nsImage: NSImage(cgImage: renderedCGImage, size: .zero))`. PeerDropPlatform may already provide a `PlatformImage.from(cgImage:)` helper — check.

- [ ] **Step 2: PetSectionView with sprite**

```swift
import SwiftUI
import PeerDropPet
import PeerDropPlatform

struct PetSectionView: View {
    var body: some View {
        VStack(spacing: 24) {
            Text("Your Pet")
                .font(.largeTitle)
            // Full-size sprite (e.g. 256×256) reusing the same renderer
            // that powers the iOS widget + menu-bar mini-sprite.
            PetSpriteView()
                .frame(width: 256, height: 256)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PetSpriteView: View {
    @EnvironmentObject var connectionManager: ConnectionManager

    var body: some View {
        if let cgImage = connectionManager.currentPetSprite {
            Image(decorative: cgImage, scale: 1.0)
                .resizable()
                .interpolation(.none)   // pixel-perfect for sprite art
        } else {
            ProgressView()
        }
    }
}
```

- [ ] **Step 3: Build verify**

```bash
xcodebuild build -scheme PeerDropMac -destination 'platform=macOS' 2>&1 | tail -3
```

If `connectionManager.currentPetSprite` doesn't exist, expose it as a public computed `CGImage?` on ConnectionManager (small edit in PeerDropCore).

- [ ] **Step 4: Commit**

```bash
git add PeerDropMac/Views/PetSectionView.swift PeerDropKit/Sources/PeerDropCore/   # if Core helper added
git commit -m "$(cat <<'EOF'
feat(m2): Pet sidebar section with sprite rendering

PetSectionView reuses PeerDropPet's renderer via CGImage →
Image(decorative:). Pixel-perfect (.interpolation(.none)) sprite at
256×256. Matches the iOS Pet hub experience.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Drag-and-drop (Dock, main window, menu bar)

**Files:**
- Create: `PeerDropMac/DragAndDrop/MacDropHandler.swift`
- Create: `PeerDropMac/DragAndDrop/DropOverlay.swift`
- Modify: `PeerDropMac/Views/MacContentView.swift` (add `.dropDestination`)
- Modify: `PeerDropMac/Views/MenuBarContent.swift` (drop target on peer rows)

Spec §4: drops never send silently — peer-selection sheet always appears.

- [ ] **Step 1: MacDropHandler**

Shared logic — given a list of URLs, raise the peer-selection sheet via ConnectionManager.

```swift
import Foundation
import PeerDropCore

@MainActor
enum MacDropHandler {
    /// Process a drop. Always raises the peer-selection sheet — never
    /// auto-sends. Returns true if accepted.
    static func handle(urls: [URL]) async -> Bool {
        await ConnectionManager.shared.handleIncomingFiles(urls: urls)
        return true
    }

    /// Process a peer-specific drop (from menu bar onto a specific peer row).
    /// Still raises a confirmation sheet — App Review compliance.
    static func handle(urls: [URL], toPeerID peerID: String) async -> Bool {
        await ConnectionManager.shared.handleIncomingFiles(urls: urls, suggestedPeerID: peerID)
        return true
    }
}
```

(`handleIncomingFiles(urls:suggestedPeerID:)` overload may need adding in PeerDropCore — small public-method extension.)

- [ ] **Step 2: DropOverlay**

```swift
import SwiftUI

struct DropOverlay: View {
    let isVisible: Bool
    var body: some View {
        if isVisible {
            RoundedRectangle(cornerRadius: 16)
                .stroke(.tint, lineWidth: 4)
                .background(.tint.opacity(0.12))
                .overlay(
                    Label("Drop to send", systemImage: "arrow.down.doc.fill")
                        .font(.title2)
                )
                .padding(20)
                .transition(.opacity)
        }
    }
}
```

- [ ] **Step 3: Wire main window**

In `MacContentView`:

```swift
@State private var isTargeted = false

// ... inside body:
NavigationSplitView { ... } detail: { ... }
.dropDestination(for: URL.self) { urls, _ in
    Task { await MacDropHandler.handle(urls: urls) }
    return true
} isTargeted: { hovering in
    isTargeted = hovering
}
.overlay(DropOverlay(isVisible: isTargeted), alignment: .center)
```

- [ ] **Step 4: Wire menu bar peer rows**

In `MenuBarPeerRow`:

```swift
HStack { ... }
.dropDestination(for: URL.self) { urls, _ in
    Task { await MacDropHandler.handle(urls: urls, toPeerID: peer.id) }
    return true
}
```

- [ ] **Step 5: Dock icon drop (already wired)**

`MacAppDelegate.application(_:open:)` (from Task 3) already routes Finder/Dock drops through `ConnectionManager.handleIncomingFiles(urls:)`. No additional code — just verify it works.

- [ ] **Step 6: Manual smoke test**

Drop a single file onto:
- The main window detail pane — peer-selection sheet appears ✓
- A menu bar peer row — confirmation sheet appears with that peer pre-selected ✓
- The Dock icon — same handling ✓

Drop multiple files — same UX. Drop a non-file URL (web link) — gracefully reject or treat as text share (depends on existing iOS handling; keep parity).

- [ ] **Step 7: Commit**

```bash
git add PeerDropMac/
git commit -m "$(cat <<'EOF'
feat(m2): drag-and-drop on Dock, main window, and menu bar

All three drop sites route through MacDropHandler which always raises
the peer-selection sheet — drops NEVER send silently (App Review
compliance per spec §4).

  - Dock icon: NSApplicationDelegate.application(_:open:) (from Task 3)
  - Main window: NavigationSplitView .dropDestination + visual overlay
  - Menu bar peer rows: per-row .dropDestination with pre-selected peer

Visual feedback during hover via DropOverlay (rounded rect with tint
border + "Drop to send" label).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: PeerDropCommands (menu bar items)

**Files:** Modify `PeerDropMac/Views/PeerDropCommands.swift` (replace placeholder).

Per spec §4 menu commands table.

- [ ] **Step 1: Define PeerDropCommands**

```swift
import SwiftUI
import PeerDropCore

struct PeerDropCommands: Commands {
    var body: some Commands {
        // File menu
        CommandGroup(replacing: .newItem) {
            Button("New Transfer…") { /* TODO: open peer picker */ }
                .keyboardShortcut("n")
            Button("Open Inbox") { /* TODO */ }
                .keyboardShortcut("i")
            Button("Import Files…") { /* TODO: NSOpenPanel */ }
                .keyboardShortcut("o")
        }

        // View menu — toggle menu bar item
        CommandGroup(after: .sidebar) {
            Button("Toggle Menu Bar Item") {
                // Read+toggle MacAppDelegate.menuBarVisible
                if let delegate = NSApp.delegate as? MacAppDelegate {
                    delegate.menuBarVisible.toggle()
                }
            }
        }

        // Peer menu — custom top-level command
        CommandMenu("Peer") {
            Button("Refresh Discovery") {
                Task { await ConnectionManager.shared.refreshDiscovery() }
            }
            .keyboardShortcut("r")
            Divider()
            Button("Trust Current Peer") { /* TODO */ }
            Button("Show Pairing SAS…") { /* TODO: present SAS sheet */ }
                .keyboardShortcut("p", modifiers: [.shift, .command])
        }

        // Window menu additions (⌘1 / ⌘2)
        CommandGroup(before: .windowList) {
            Button("Chat") { /* TODO: focus most-recent chat window */ }
                .keyboardShortcut("1")
            Button("Inbox") { /* TODO: open inbox window */ }
                .keyboardShortcut("2")
        }

        // Help menu
        CommandGroup(replacing: .help) {
            Button("PeerDrop Help") {
                if let url = URL(string: "https://github.com/hanfour/peer-drop#readme") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("Send Feedback") {
                if let url = URL(string: "mailto:hanfourhuang@gmail.com?subject=PeerDrop%20Feedback") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}
```

Several items have TODO comments — those that need handlers but the handler doesn't exist on macOS yet. Fill the stubs to either:
- Call into ConnectionManager for the action (preferred)
- Show a "not yet implemented" alert (acceptable for first-cut; track as M2 follow-up)

- [ ] **Step 2: Build verify**

```bash
xcodebuild build -scheme PeerDropMac -destination 'platform=macOS' 2>&1 | tail -3
```

- [ ] **Step 3: Manual smoke test**

Launch the app. Click each menu item or use the keyboard shortcut. Verify:
- File → New Transfer (⌘N) does *something* (raises peer picker OR shows TODO alert; both are acceptable)
- File → Open Inbox (⌘I) — same
- File → Import Files (⌘O) — opens an NSOpenPanel-equivalent
- View → Toggle Menu Bar Item — flips the menu bar icon visibility
- Peer → Refresh Discovery (⌘R) — triggers a discovery cycle
- Window → Chat (⌘1) — focuses chat window (if one is open) or shows TODO
- Help → PeerDrop Help — opens GitHub
- Help → Send Feedback — opens mailto:

- [ ] **Step 4: Commit**

```bash
git add PeerDropMac/Views/PeerDropCommands.swift
git commit -m "$(cat <<'EOF'
feat(m2): menu commands (File/View/Peer/Window/Help)

Implements the command set from spec §4 menu commands table:
  - File: New Transfer (⌘N), Open Inbox (⌘I), Import Files (⌘O)
  - View: Toggle Sidebar (native), Toggle Menu Bar Item
  - Peer: Refresh Discovery (⌘R), Trust Current Peer, Pairing SAS (⇧⌘P)
  - Window: Chat (⌘1), Inbox (⌘2)
  - Help: PeerDrop Help, Send Feedback

Several items are stub-implemented (raise an alert or open a URL)
and will be wired to real flows as the UI surface grows. Keyboard
shortcuts all bind correctly.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: Settings scene

**Files:** Modify `PeerDropMac/Views/MacSettingsView.swift` (replace placeholder).

Spec §4 doesn't fully spec Settings — port a sensible subset of `PeerDrop/UI/SettingsView.swift`. macOS users expect a tabbed Settings window (`⌘,`), not a full-screen settings page.

- [ ] **Step 1: Tabbed Settings**

```swift
import SwiftUI
import PeerDropCore

struct MacSettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gear") }
                .frame(width: 520, height: 360)

            ProfileSettingsTab()
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
                .frame(width: 520, height: 360)

            RelaySettingsTab()
                .tabItem { Label("Relay", systemImage: "network") }
                .frame(width: 520, height: 360)
        }
    }
}

struct GeneralSettingsTab: View { /* device name, theme, etc. */ }
struct ProfileSettingsTab: View { /* user profile, identity fingerprint */ }
struct RelaySettingsTab: View { /* worker URL override, relay enable toggle */ }
```

Use existing iOS Settings rows where possible — pull the granular `@AppStorage` / `ObservableObject` toggles from `PeerDrop/UI/Settings/`. Most of those are cross-platform SwiftUI Forms.

- [ ] **Step 2: Build + manual test**

Launch the .app, press `⌘,`. Verify Settings window opens with the 3 tabs. Each tab shows correct controls.

- [ ] **Step 3: Commit**

```bash
git add PeerDropMac/Views/
git commit -m "$(cat <<'EOF'
feat(m2): tabbed Settings scene (General / Profile / Relay)

Native macOS pattern: TabView in the Settings scene reachable via ⌘,
or App menu → Preferences. Three tabs:
  - General: device name, theme, default downloads dir
  - Profile: identity fingerprint, public key, display name
  - Relay: worker URL override, enable/disable toggle

Reuses iOS settings rows (cross-platform SwiftUI Forms) where the
controls translate cleanly.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: Keyboard navigation + accessibility

**Files:** Mostly polish — `MacSidebar.swift`, `MacContentView.swift`, command shortcuts already in Task 11.

Per spec §4: "Full keyboard-first navigation: sidebar arrow keys, ⌘1–⌘9 for sections, ⌘F peer search, ⌘⇧K new chat."

- [ ] **Step 1: Sidebar arrow keys**

SwiftUI `List` with `selection:` Binding handles arrow-key navigation natively. Verify by launching and pressing up/down on the sidebar.

- [ ] **Step 2: ⌘1-⌘4 jump to sections**

Add commands in `PeerDropCommands`:

```swift
CommandGroup(after: .windowList) {
    Button("Nearby")  { selectSection(.nearby)  }.keyboardShortcut("1", modifiers: [.command, .option])
    Button("Trusted") { selectSection(.trusted) }.keyboardShortcut("2", modifiers: [.command, .option])
    Button("Relay")   { selectSection(.relay)   }.keyboardShortcut("3", modifiers: [.command, .option])
    Button("Pet")     { selectSection(.pet)     }.keyboardShortcut("4", modifiers: [.command, .option])
}

private func selectSection(_ section: MacSidebarSection) {
    // Use NotificationCenter or a global observable to flip MacContentView.selection
}
```

(Modifier choice `⌘⌥` avoids collision with ⌘1 (chat window) from Task 7.)

- [ ] **Step 3: ⌘F peer search**

In NearbyTab (reused from iOS), the existing search bar uses `.searchable(text:)`. The keyboard shortcut ⌘F should focus it natively. Verify.

- [ ] **Step 4: VoiceOver labels**

Run Accessibility Inspector while the app is running. Verify each sidebar item has a proper accessibility label, each toolbar button is reachable, the menu bar icon announces state changes.

- [ ] **Step 5: Commit**

```bash
git add PeerDropMac/
git commit -m "$(cat <<'EOF'
feat(m2): keyboard navigation + accessibility pass

  - ⌘⌥1–⌘⌥4 jump to sidebar sections
  - ⌘F focuses peer search (handled by iOS .searchable reuse)
  - Sidebar arrow keys work natively via SwiftUI List
  - VoiceOver labels verified for sidebar items, menu bar icon, and
    command items

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 14: macOS-specific Voice button hiding

**Files:** Whatever iOS files surface Voice UI that the macOS audit didn't catch.

Per spec line 326 + 354: M2 has voice UI hidden; M3 ships it.

- [ ] **Step 1: Identify Voice surfaces in reused UI files**

Look for `voiceCallManager`, `VoiceCallView`, `callRequest`, `.callRequest` references in `PeerDrop/UI/` files that the macOS target reuses (i.e. files NOT in the exclude list).

```bash
grep -rln "VoiceCallManager\|voiceCallManager\|VoiceCallView\|startVoiceCall" PeerDrop/UI/ --include="*.swift"
```

- [ ] **Step 2: Wrap voice-trigger buttons in `#if os(iOS)` or feature flag**

For each Voice trigger in a reused View, add a guard:

```swift
#if os(iOS)
Button("Voice Call") { /* existing handler */ }
#endif
```

Or use a SwiftUI conditional with a runtime check via a Platform-layer flag:

```swift
if Self.isVoiceUIAvailable {
    Button("Voice Call") { ... }
}
```

Where `Self.isVoiceUIAvailable` is a cross-module static that's `true` on iOS and `false` on macOS in M2 (M3 flips it to `true` on macOS too).

Prefer the runtime flag — easier for M3 to unhide.

- [ ] **Step 3: Build verify**

```bash
xcodebuild build -scheme PeerDropMac -destination 'platform=macOS' 2>&1 | tail -3
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' 2>&1 | tail -3
xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' 2>&1 | grep "Executed " | tail -2
```

iOS regression: 635 tests still pass; voice buttons still show on iOS.
macOS: voice buttons hidden in chat header, peer row context menu.

- [ ] **Step 4: Commit**

```bash
git add PeerDrop/UI/
git commit -m "$(cat <<'EOF'
feat(m2): hide Voice UI on macOS (M3 unhides)

Wraps voice-trigger buttons (chat header phone icon, peer row context
menu "Voice Call", any in-flight call banner) in a runtime check
against a Platform-layer `isVoiceUIAvailable` flag. M2 sets the flag
to false on macOS; M3 will flip it to true after the custom NSWindow
incoming-call panel ships.

iOS behavior unchanged. Verified via 635-test regression sweep.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 15: Manual smoke test + iOS regression check

- [ ] **Step 1: Run the full iOS test sweep**

```bash
xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' 2>&1 | grep "Executed " | tail -2
```

Expected: **635 tests pass** (M1d-5 baseline, unchanged after M2).

- [ ] **Step 2: Run PeerDropKit tests**

```bash
cd PeerDropKit && swift test 2>&1 | grep "Executed " | tail -2 && cd ..
```

Expected: **614 tests pass** (7 skipped baseline).

- [ ] **Step 3: macOS build clean**

```bash
xcodebuild build -scheme PeerDropMac -destination 'platform=macOS' 2>&1 | tail -3
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Manual smoke test — alpha milestone checklist**

Per spec §7 M2: "Alpha milestone — pairing, cross-platform chat, file transfer (incl. relay), Pet display all work. Voice UI hidden."

Two-device test (Mac + iPhone running latest iOS build):

- [ ] Mac launches; main window shows NavigationSplitView with Nearby tab selected
- [ ] iPhone + Mac discover each other via Bonjour (Nearby section populates)
- [ ] Pairing SAS dance: tap "Pair" on iPhone, "Trust Current Peer" on Mac, SAS sheet shows on both, match → both peers move to Trusted
- [ ] Chat: open chat on Mac (⌘1 or peer row tap), send "Hello from Mac" → arrives on iPhone within 1-2s; reply from iPhone arrives in same chat window
- [ ] Drag a small file (~1MB) onto Mac's main window → peer-selection sheet → confirm → transfer completes on iPhone
- [ ] Drag a file onto Mac's Dock icon → same flow
- [ ] Drag a file onto a peer row in Mac's menu bar popover → same flow (with peer pre-selected)
- [ ] Relay test: turn off iPhone's WiFi, leave Cellular on; iPhone connects to Mac via relay → chat still works
- [ ] Pet section on Mac: pet sprite renders at 256×256 with no scaling artifacts
- [ ] Menu bar mini-sprite (60×60) renders the same pet
- [ ] Settings: ⌘, opens tabbed Settings window
- [ ] Quit (⌘Q) flushes chat persists; relaunch shows history intact

If ANY of these fail, capture the failure mode and fix before final commit. Goal: M2 is shippable to internal TestFlight Mac group as alpha.

- [ ] **Step 5: Note remaining work for M3 / M4**

In the worktree, create a quick `docs/superpowers/notes/2026-05-27-m2-followups.md` with anything noticed during smoke testing that didn't fit in M2 scope (typical alpha findings: a few rough edges in NearbyTab on macOS, sidebar width persistence quirks, etc.). M3/M4 will pick these up.

---

## Task 16: Final tag + PR

- [ ] **Step 1: Tag**

```bash
git tag -a m2-macos-ui-shell -m "M2 done: macOS UI shell ships. iPhone ↔ Mac pairing, chat, file transfer (incl. relay) work. Pet display works. Voice UI hidden until M3. Internal TestFlight alpha unblocked."
```

- [ ] **Step 2: Push and open PR (base = main)**

```bash
git push -u origin <worktree-branch>:feat/m2-macos-ui-shell
gh pr create --base main --head feat/m2-macos-ui-shell --title "feat(m2): macOS UI shell (alpha milestone)" --body "..."
```

PR body should call out:
- **What ships**: PeerDropMac app target builds + runs; iPhone↔Mac pairing/chat/transfer/relay/pet work; menu bar item + commands wired
- **What's hidden**: Voice UI (M3 ships)
- **Test plan checklist** (from Task 15 Step 4)
- **Predecessors**: M0 → M1d-5 (all 11 PRs)
- **Next milestone**: M3 (Mac voice calling)

- [ ] **Step 3: Update memory**

After merge, update `project-macos-port.md`:
- Mark M2 ✅
- Note PR # and SHA
- Record any architectural decisions surfaced during execution

---

## Done

After M2: **alpha milestone**. iPhone + Mac users in the internal TestFlight group can pair, chat, transfer files (incl. relay), see their pet. Voice UI hidden but the rest is shippable. iOS v5.4.0 + macOS v6.0.0 builds side-by-side.

**Next:** M3 (Mac voice calling — 5-7 days), then M4 (submission prep — 4-6 days + 1-2 week review buffer).

## Lessons from M1d-4/M1d-5 that apply here

1. **Pre-task audit subagent surfaces hidden iOS-specific code.** Don't trust the spec's enumeration of cross-platform views — grep first.
2. **SwiftUI `.dropDestination`, `.fileImporter`, `.searchable` are cross-platform since iOS 14 / macOS 11.** Prefer these over `UIDocumentPickerRepresentable` / `UIViewControllerRepresentable` wrappers.
3. **Some iOS Views are too entangled to refactor for cross-platform reuse.** Don't fight — write a Mac-specific replacement in `PeerDropMac/Views/` and `excludes:` the iOS original.
4. **Test on both platforms after every UI task.** macOS may surface latent iOS-only API usage that the existing test suite (iOS-only) never exercises.
5. **App Review compliance for drag-and-drop**: drops NEVER auto-send. Always a confirmation sheet — for both Dock drops, main window drops, and menu bar peer-row drops.
6. **Mac App Store sandbox is non-negotiable.** Entitlements file must enable `app-sandbox: true` plus the specific capabilities needed (networking, file access, Bluetooth, multicast).

## Open Items After M2

- M3: Mac voice calling (custom NSWindow ringer, APNs alert push, DND integration, NSApplication.registerForRemoteNotifications, Worker KV schema update)
- M4: Mac screenshots (3 sizes × modes × 5 languages), metadata translation, `release_mac` lane, ASC macOS platform enablement, IAP re-attach (Playwright), reviewer notes, release-runbook updates
