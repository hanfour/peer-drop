# macOS Port Design — PeerDrop v6.0

**Date:** 2026-05-24
**Status:** Approved, pending implementation plan
**Author:** Brainstormed with Claude (Opus 4.7)

## Decisions Recap

| Decision | Choice |
|---|---|
| Functional scope | Full feature parity with iOS |
| Technical approach | Native macOS target (not Catalyst) |
| Main window + menu bar | Main window + `MenuBarExtra` (status item) |
| Distribution | Mac App Store only |
| Minimum macOS | macOS 14 Sonoma |
| Voice calling in v6.0 | Fully implemented (no defer) |
| Architecture | Local SPM package (`PeerDropKit`) + two thin app targets |

## §1 — SPM Package Boundary

`PeerDropKit/` is a local Swift Package at the repo root, shared by `PeerDropApp-iOS`, `PeerDropApp-macOS`, and `PeerDropWidget`. Five product modules:

| Module | Contents | Platform deps |
|---|---|---|
| `PeerDropCore` | `ConnectionManager`, `ChatManager`, `DeviceRecordStore`, `UserProfile`, `InboxService`, `FeatureSettings`, `ScreenshotModeProvider`, `ConnectionMetrics` | Foundation only |
| `PeerDropTransport` | Bonjour discovery, `PeerConnection`, WebRTC wrapper, `RelaySession`, `NetworkFingerprint`, `TailnetPeerStore` | Network, WebRTC SPM |
| `PeerDropSecurity` | `PeerIdentity`, `DeviceIdentity`, `ChatDataEncryptor`, `TrustedContact`, Double Ratchet, SAS, relay crypto | CryptoKit |
| `PeerDropProtocol` | Wire format, message envelope, version negotiation (incl. PR7 `peerProtocolVersion`) | Foundation only |
| `PeerDropPet` | `PetGenome`, `SpeciesCatalog`, `PetRendererV3`, `SpriteService`, `PaletteSwap`, atlas decoding | CoreGraphics, ZIPFoundation |

Dependency direction (strict, no cycles):

```
PeerDropPet ────┐
PeerDropSecurity ─┐
PeerDropProtocol ─┼──> PeerDropCore ──> (app targets)
PeerDropTransport ┘
```

**Hard rules (enforced by CI):**
- No `import UIKit` / `import AppKit` / `import WidgetKit` anywhere in `PeerDropKit/Sources/`
- Platform-abstracted types (e.g. `PlatformImage`, `PlatformColor`) live in `PeerDropCore` via `#if canImport` typealiases:

```swift
// PeerDropCore/PlatformAliases.swift
#if canImport(UIKit)
import UIKit
public typealias PlatformImage = UIImage
public typealias PlatformColor = UIColor
#elseif canImport(AppKit)
import AppKit
public typealias PlatformImage = NSImage
public typealias PlatformColor = NSColor
#endif
```

**Resources:** Pet atlases and `Pets/` move into SPM resource bundle (`Package.swift` uses `.process` / `.copy`). Widget accesses via `Bundle.module`, retiring the current project.yml workaround that references 7 individual `.swift` paths.

## §2 — iOS-Only Mechanism Mapping

| iOS mechanism | macOS counterpart | Strategy |
|---|---|---|
| CallKit | None | Custom incoming-call panel (floating `NSWindow`, no title bar); `AVAudioPlayer` ringtone; switches to call window on answer |
| VoIP push (PushKit) | None | Regular APNs alert push; tapping notification wakes app, shows panel. Same device token; server distinguishes by `platform` field |
| Live Activities / Dynamic Island | None | Menu bar item displays live state (green dot + timer during call, progress ring during transfer) |
| WidgetKit | macOS 14+ desktop + Notification Center widgets | Widget target becomes multi-platform; same timeline provider |
| App Attest | macOS 14+ supported | `DCAppAttestService` API identical; bundle ID shared, no Worker change |
| Background mode `voip` | N/A (no concept) | Menu bar item = always resident → WebRTC + relay socket persist. `LSUIElement: false`, main window closeable but process survives |
| Background mode `bluetooth-*` | N/A | BLE on macOS doesn't need declaration; persistence via menu bar |
| Background mode `remote-notification` | N/A | APNs delivered to NSUserNotificationCenter; system wakes process |
| Nearby Interaction (UWB) | No UWB chip | Hide entirely; `FeatureSettings.uwbAvailable = false` on macOS |
| `NSLocalNetworkUsageDescription` | macOS 15+ only | Add to Info.plist (harmless on macOS 14) |
| `UIBackgroundTaskIdentifier` | N/A (no suspension) | `#if os(iOS)` isolation |
| `UIPasteboard` | `NSPasteboard.general` | `PlatformPasteboard` protocol |
| `UIImpactFeedbackGenerator` | None (Touch Bar deprecated) | `HapticFeedback` protocol; macOS = no-op |
| `UIDevice.current.name` | `Host.current().localizedName` / `SCDynamicStoreCopyComputerName` | `DeviceNameProvider` protocol |
| APNs token registration | `NSApplication.shared.registerForRemoteNotifications()` | Same signature, swap UIApplication ↔ NSApplication |
| `UIDocumentPickerViewController` | `NSOpenPanel` / window drop / Dock drop | `FilePickerService` protocol |
| `UIActivityViewController` | `NSSavePanel` + Finder reveal | Same protocol |

**Incoming call panel specifics:**
- 380×140, vibrancy background, avatar + name + Accept/Decline buttons
- `NSWindow.level = .floating`, `collectionBehavior = [.canJoinAllSpaces, .stationary]`
- `AVAudioPlayer(numberOfLoops: -1)`; respects Do Not Disturb via `UNUserNotificationCenter.notificationSettings`
- Auto-dismiss after 30s if not answered (matches iOS CallKit timing)

**MAS Sandbox entitlements:**
```
com.apple.security.app-sandbox = true
com.apple.security.network.client = true
com.apple.security.network.server = true            # Bonjour listener
com.apple.security.device.audio-input = true
com.apple.security.device.bluetooth = true
com.apple.security.files.user-selected.read-write = true
com.apple.security.files.downloads.read-write = true
com.apple.developer.networking.multicast = true     # Bonjour browse
```

## §3 — Core UIKit Decoupling (M0 Scope)

Nine files in `PeerDrop/Core/` import UIKit. Each gets a protocol abstraction injected at app-init time:

| File | Change |
|---|---|
| `ImageCache.swift` | `UIImage` → `PlatformImage`; cache key/value updated; decode via `PlatformImage(data:)` |
| `PushNotificationManager.swift` | `RemoteNotificationRegistering` protocol; iOS uses `UIApplication`, macOS uses `NSApplication` |
| `ClipboardSyncManager.swift` | `PlatformPasteboard` protocol (`string`, `image`, `changeCount`) |
| `HapticManager.swift` | `HapticFeedback` protocol; macOS = no-op |
| `UserProfile.swift` | Avatar → `PlatformImage`; default name via `DeviceNameProvider` |
| `ArchiveManager.swift` | `PlatformImage.jpegData(quality:)` extension; macOS wraps `NSBitmapImageRep` |
| `ErrorReporter.swift` | `SystemInfoProvider` protocol (osVersion, deviceModel); macOS uses `sysctlbyname("hw.model")` |
| `ConnectionManager.swift` | Background task work `#if os(iOS)`; lifecycle observer → `AppLifecycleObserver` protocol |
| `PeerIdentity.swift` | `DeviceFingerprintProvider` protocol; macOS uses IOPlatformUUID |

All protocols declared in `PeerDropCore` with default mock implementations. Real implementations live in the app targets and are injected at startup. `ConnectionManager.init` gains optional parameters (default nil → mocks for unit tests).

**Test migration:** ~70% of the 913 existing tests are cross-platform and move into SPM test bundles. The rest stay in iOS app target (VoiceCallTests, CallKitManager).

**Estimated effort:** 3–5 working days as a single PR; iOS shipping behaviour unchanged.

## §4 — macOS UI Shell

### Entry point

```swift
@main
struct PeerDropMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var connectionManager = ConnectionManager.shared

    var body: some Scene {
        WindowGroup("PeerDrop") { MainView().environmentObject(connectionManager) }
            .commands { PeerDropCommands() }

        Window("Chat", id: "chat") { ChatWindow() }
            .keyboardShortcut("1", modifiers: .command)

        Settings { SettingsView() }

        MenuBarExtra(isInserted: $appDelegate.menuBarVisible) {
            MenuBarContent()
        } label: {
            MenuBarStatusIcon(state: connectionManager.aggregateState)
        }
        .menuBarExtraStyle(.window)
    }
}
```

`LSUIElement: false`, `NSSupportsAutomaticTermination: false`, `NSSupportsSuddenTermination: false`. AppDelegate handles:
- `application(_:open:)` — Finder/Dock drop
- `applicationShouldHandleReopen(_:hasVisibleWindows:)` — Dock click reopens main window
- `applicationWillTerminate(_:)` — `ConnectionManager.flushAllPendingPersists()`

### Main window layout

`NavigationSplitView` (sidebar + detail). Sidebar lists: Nearby / Trusted / Relay / Pet. Detail uses `NavigationStack` with path-based routing (URL scheme `peerdrop://chat/<peerID>` reuses the same path). Sidebar width persisted via `@AppStorage("sidebar.width")`.

### Menu bar item (`MenuBarExtra`, `.window` style, ~360×500)

Sections: status header, peers list (with inline ⊕ Send), pending transfers, Pet mini-sprite, Open/Quit. Pet sprite reuses `PeerDropPet` renderer (same `CGImage` output as main window and widget).

### Menu commands (`PeerDropCommands`)

| Menu | Items |
|---|---|
| File | New Transfer (⌘N), Open Inbox (⌘I), Import Files (⌘O) |
| View | Show/Hide Sidebar (⌘^S), Toggle Menu Bar Item |
| Peer | Refresh Discovery (⌘R), Trust Current Peer, Show Pairing SAS (⇧⌘P) |
| Window | Chat (⌘1), Inbox (⌘2) |
| Help | PeerDrop Help, Send Feedback |

### Drag-and-drop

All three targets accept drops: main window (full overlay), Dock icon (`application(_:open:)`), menu bar popover (drag-to-peer-row, direct send). Implementation: SwiftUI `.dropDestination(for: URL.self)`. **Drops never send silently** — peer selection sheet always appears (App Review compliance).

### Multi-window strategy

- Main window — discovery / settings / pet hub
- Chat windows — one per peer (`Window(id: "chat-\(peerID)")`)
- Transfer windows — large transfers auto-detach
- Call windows — floating, independent (see §2)

### Keyboard & theming

Full keyboard-first navigation: sidebar arrow keys, `⌘1–⌘9` for sections, `⌘F` peer search, `⌘⇧K` new chat. System light/dark theme, accent color reuses iOS `AccentColor` asset, sidebar uses `.sidebar` material, SF Symbols throughout.

## §5 — Distribution, Signing, Worker

### Bundle IDs

| Target | Bundle ID |
|---|---|
| iOS app | `com.hanfour.peerdrop` |
| macOS app | `com.hanfour.peerdrop` (same) |
| iOS widget | `com.hanfour.peerdrop.widget` |
| macOS widget | `com.hanfour.peerdrop.widget-mac` (must differ per platform) |
| App Group | `group.com.hanfour.peerdrop` (both platforms) |
| Keychain group | `$(AppIdentifierPrefix)com.hanfour.peerdrop` (both platforms) |

**Keychain note:** iOS and macOS keychains are separate stores. Without iCloud Keychain (we don't use it), a user's IdentityKey on iOS does not sync to Mac. Mac generates an independent device identity on first launch — the two devices appear as separate peers and require SAS pairing. This matches the trust model.

### ASC structure

Single App ID `6759594513` with two platform tabs (iOS / macOS).

Shared: app name, icon, privacy policy, support URL, IAP catalog (`tip.small/medium/large`), store-page metadata frame.
Per-platform: screenshots, version number, build number.

### Fastlane changes

- New `release_mac` lane parallel to `release`
- `deliver` action: `platform: "osx"`
- `gym` scheme: `PeerDropMac`
- `fastlane/metadata/` → split into `ios/` and `macos/` subdirectories
- `fastlane/screenshots/` → same split

### MAS first-time setup (manual, not automatable)

1. developer.apple.com → Identifiers → enable macOS platform on `com.hanfour.peerdrop`
2. Enable: Push Notifications, App Groups, Keychain Sharing, Associated Domains
3. `fastlane match nuke` then re-sync; add new cert types: `mac_app_store`, `mac_installer_distribution`
4. First Mac build upload — IAP must be re-attached via Playwright ASC web-UI flow (carries `feedback-asc-iap-quirks` constraints)

### Worker changes

- KV record schema: device entries gain a `platform: "ios" | "macos"` field. KV is schema-less — existing records read as `platform: undefined` and are treated as `"ios"` by a default coalesce; lazy-rewrite on next device check-in. No migration script needed
- APNs payload branching: macOS devices get alert push (no VoIP) for incoming calls
- App Attest: zero changes, server logic unaware of platform
- v5.3 X-API-Key fallback (expires 2026-06-14): Mac starts from Bearer, no legacy support

### Version strategy

- iOS continues `5.x` line for incremental work
- v6.0.0 ships simultaneously on both platforms — iOS = SPM rebuild (functionally = v5.4), macOS = first release
- After v6.0.0, platforms version independently

## §6 — Testing Strategy

### Package-level tests (`PeerDropKit/Tests/`)

| Bundle | Platforms | Test count (approx) |
|---|---|---|
| `PeerDropCoreTests` | iOS + macOS | 200 |
| `PeerDropTransportTests` | iOS + macOS | 150 |
| `PeerDropSecurityTests` | iOS + macOS | 250 |
| `PeerDropProtocolTests` | iOS + macOS | 80 |
| `PeerDropPetTests` | iOS + macOS | 150 |

Run via `swift test --triple arm64-apple-ios16.0-simulator` and `swift test --triple arm64-apple-macos14.0`. macOS runs ~3× faster than xcodebuild.

`PeerDropPetTests` adds an assertion that every v5 zip contains both `walk` and `idle` keys — closing the gap that let the bug in v5.3.3/v5.3.4 ship.

### App-target tests

| Bundle | Platform | Coverage |
|---|---|---|
| `PeerDropApp-iOS-Tests` | iOS | CallKit, PushKit, Live Activity, iOS Widget, DocumentPicker, real HapticManager |
| `PeerDropApp-macOS-Tests` | macOS | `MenuBarExtra` updates, multi-window state sync, `NSPasteboard`, `NSOpenPanel`, Dock drop, URL routing, call panel `NSWindow.level`, ringtone, menu bar Pet sprite frame advance |
| `PeerDropUITests` | iOS | Unchanged |
| `PeerDropMacUITests` | macOS | Onboarding, first-pair SAS, drop targets, chat window, Settings |

### Platform-abstraction coverage

The 7 protocols introduced in §3 (`RemoteNotificationRegistering`, `PlatformPasteboard`, `HapticFeedback`, `DeviceNameProvider`, `SystemInfoProvider`, `AppLifecycleObserver`, `DeviceFingerprintProvider`) plus the `PlatformImage` typealias and platform-specific `jpegData(quality:)` extension each require (a) mock + injection test at package layer and (b) real-implementation smoke test at app layer per platform.

### CI matrix

```yaml
jobs:
  swift-package-tests:
    strategy:
      matrix:
        sdk: [iphonesimulator, macosx]
    runs-on: macos-15
  ios-app-tests:
    needs: swift-package-tests
  macos-app-tests:
    needs: swift-package-tests
  lint-imports:
    script: |
      ! grep -r "^import UIKit\|^import AppKit\|^import WidgetKit" PeerDropKit/Sources/
```

`lint-imports` is hard enforcement — failing this blocks the PR.

### Manual test checklist (release-runbook.md addition)

1. Close main window → menu bar item remains, connection holds
2. Drop file on Dock → peer selection sheet appears (never silent send)
3. iPhone-initiated call → APNs notification → tap → panel appears floating
4. 30s no answer → panel auto-dismisses
5. After connect → call window independent, follows across Spaces
6. SAS pairing: iPhone ↔ Mac first-pair
7. Cross-platform chat post-trust (incl. v5.4 relay path)
8. Pet animation sync across main window, menu bar, widget
9. Do Not Disturb: ringtone silent, panel still appears

## §7 — Milestones

Five PR stages; main is shippable after every merge.

### M0 — Core UIKit decoupling
Scope: §3 work (9 files, protocol abstractions, `PlatformImage` typealias, `#if os(iOS)` isolation). Single PR, 3–5 days. iOS behaviour identical to v5.4; 913 existing tests still pass; `lint-imports` CI added in warn-only mode. Ships as iOS v5.5 internal refactor (no ASC submission needed).

### M1 — SPM package split (split into 4 sub-milestones, 2026-05-25)

Investigation during M1 planning surfaced that the original spec underestimated this work — the spec assumed Pet renderer was UIKit-free (wrong) and only counted 5 of the 13 top-level dirs in `PeerDrop/`. M1 is restructured as four PRs that each ship independently and keep `main` always-shippable:

- **M1a — Pet UIKit decoupling.** Apply M0-style platform abstraction to `Pet/Renderer/*` (5 files) + `Pet/Engine/PetEngine.swift`. Extend `PlatformImage` extension family with a `platformGraphicsContext` helper (cross-platform equivalent of `UIGraphicsImageRenderer`). `PetPalettes` already uses SwiftUI.Color which is cross-platform — no work needed there. ~3–4 days, ~12 tasks.
- **M1b — Voice cleanup.** Split `Voice/` along the CallKit boundary. iOS-only (`CallKitManager`, the CallKit-specific paths inside `VoiceCallManager`) stays in app target. Cross-platform (`WebRTCClient`, `SDPSignaling`, `VoicePlayer`, `VoiceRecorder`, the transport-layer parts of `VoiceCallManager`/`VoiceCallSession`) gets ready to move into `PeerDropTransport`. ~2–3 days, ~6 tasks.
- **M1c — SPM scaffold + empty modules.** Create `PeerDropKit/Package.swift` with the 5 product modules + dependency graph. Modules are EMPTY at this point — just compile. `lint-imports` upgraded to error. ~2 days, ~6 tasks.
- **M1d — File migration into modules.** Move ~90 files into their target modules (including new top-level dirs `Discovery/`, `Voice/` transport-side, `Telemetry/`, etc.), fix imports, update `@testable import` in tests, refactor `project.yml` so both app target + widget consume the SPM package instead of path-referencing individual `.swift` files. Move Pet/ resources into SPM resource bundle. ~3–4 days, ~10 tasks.

Total realistic M1: **~10–13 working days, ~34 tasks across 4 PRs**. Original "5–7 days, 1 PR" estimate was wildly optimistic.

Both app targets build after M1d; ~820 tests in SPM bundles + ~90 in app targets.

### M2 — macOS UI shell (no calling)
Scope: §4 — create `PeerDropApp-macOS` target, SwiftUI shell, `NavigationSplitView`, `MenuBarExtra`, AppDelegate (Dock drop / reopen), menu commands, NSOpenPanel/NSSavePanel, `NSPasteboard`, Pet sprite in menu bar. 7–10 days. **Alpha milestone** — pairing, cross-platform chat, file transfer (incl. relay), Pet display all work. Voice UI hidden. Internal TestFlight Mac group opens.

### M3 — Mac voice calling
Scope: §2 — custom incoming-call `NSWindow`, ringtone, DND integration, call window, APNs alert push, Worker KV schema update (lazy backfill), `NSApplication.registerForRemoteNotifications`. 5–7 days (incl. Worker). Bidirectional iPhone ↔ Mac calling, 30s timeout, DND-aware, cross-Space.

### M4 — Submission prep
Scope: Mac screenshots (3 sizes × modes × 5 languages), metadata translation (`fastlane/metadata/macos/`), `release_mac` lane, ASC macOS platform enablement, capability setup, IAP re-attach (Playwright), reviewer notes, release-runbook updates. 4–6 days + 1–2 weeks Apple review buffer. **Beta milestone** — first Mac build `WAITING_FOR_REVIEW`. iOS v6.0.0 (SPM rebuild) ships same day.

### Schedule summary

| Stage | Days | Cumulative |
|---|---|---|
| M0 | 3–5 | 1 wk |
| M1a Pet decoupling | 3–4 | 1.5–2 wk |
| M1b Voice cleanup | 2–3 | 2–2.5 wk |
| M1c SPM scaffold | 2 | 2.5–3 wk |
| M1d File migration | 3–4 | 3–4 wk |
| M2 | 7–10 | 5–6 wk |
| M3 | 5–7 | 6–7 wk |
| M4 | 4–6 | 7–8.5 wk |
| Apple review buffer | 1–2 wk | **8–10.5 wk** |

(Original spec estimated 7–9 wk total. The M1 underestimation pushes the realistic ship target by ~2 weeks.)

### Parallelization

- M2 can start late in M1 once ConnectionManager builds on macOS
- M3 Worker payload-branching logic can deploy during M0/M1 (clients not sending `platform` field yet — lazy default works)
- M4 screenshot production can begin from M2 alpha build

### Risk register

| Risk | Impact | Mitigation |
|---|---|---|
| `swift test` iOS-simulator edge cases | M0/M1 blocked | Fallback to `xcodebuild test -scheme PeerDropKit-iOS` |
| MAS sandbox blocks Bonjour behaviour | M2 blocked | `multicast` entitlement listed in §2; add others as discovered |
| Apple rejects self-drawn call panel | M4 rejected | Slack/Discord/FaceTime precedent — low risk |
| ASC IAP attach quirks (Mac first time) | M4 blocked | `feedback-asc-iap-quirks` + Playwright flow already documented |
| Both-platform v6.0.0 sync release slips | Marketing message dilutes | Accept staggered release (iOS first, Mac next week); version still aligned |

## Open Items for Plan

The implementation plan (next step via `writing-plans` skill) will need to expand:

1. M0 file-by-file change list with protocol signatures
2. SPM `Package.swift` skeleton with module/dependency declarations
3. Concrete `project.yml` diff for adding `PeerDropApp-macOS` target
4. Worker KV record schema update + APNs payload branching logic + deployment runbook step
5. ASC checklist for first-time Mac platform enablement
6. CI workflow YAML

## References

- CLAUDE.md memories: `[[feedback-asc-iap-quirks]]`, `[[feedback-capability-add-twostep-ship]]`, `[[bug-fix-lesson-walk-frames]]`
- Current relay crypto state: v5.4 PRs #37–#44 merged on `main`
- Existing release runbook: `docs/release/release-runbook.md`
- Current widget shared-files hack: `project.yml` lines 146–168
