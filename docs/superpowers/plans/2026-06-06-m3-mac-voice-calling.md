# M3 — Mac Voice Calling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship bidirectional iPhone ↔ Mac voice calling. Custom NSWindow incoming-call panel (Spaces-floating, DND-aware, 30s auto-dismiss), active-call window (independent, follows across Spaces), bundled CAF ringtone, APNs alert push (no PushKit on macOS — alert push reliably wakes the Mac), Worker per-platform routing. Final hand-off flips `MacFeatureFlags.isVoiceUIAvailable = true` and un-excludes `Voice/**` so the phone affordance materialises in cross-platform chat surfaces.

**Architecture:** New `MacCallProvider` in `PeerDropMac/Voice/` (symmetric with iOS `PeerDrop/UI/Voice/`) conforms to the existing cross-platform `CallProvider` protocol — same surface as `CallKitManager`, but draws SwiftUI panels hosted in two dedicated `NSWindow`s (incoming = `NSPanel` for FaceTime-style "no app-activate" behavior; active = regular `NSWindow`). `VoiceCallManager` and the rest of PeerDropTransport stay untouched. A new `MacRemoteNotificationRegistering` adapter wires `NSApplication.shared.registerForRemoteNotifications()` into `PlatformDependencies`. The Worker gains `/v2/call/:deviceId` as a separate endpoint from `/v2/invite/` (semantic separation prevents inviteKind drift) and reads `device:{id}.platform` for per-platform APNs topic + payload selection. `PushNotificationManager`'s hardcoded `"platform": "ios"` is generalized via a new `PlatformDependencies.platformIdentifier` injection point — testable and visionOS-extension-friendly.

**Tech Stack:** Swift 5.9 / SwiftUI / AppKit (`NSPanel`, `NSWindow`, `NSWindowController`, `NSVisualEffectView`, `NSHostingView`), `AVAudioPlayer` (ringtone), `AVCaptureDevice.requestAccess(for: .audio)` (mic permission). `UserNotifications` for DND. TypeScript / Cloudflare Workers KV / JWT-signed APNs HTTP/2 (reuse existing `APNS_KEY_P8`, add `APNS_BUNDLE_ID_MAC` binding). Builds: `xcodebuild build -scheme PeerDropMac -destination 'platform=macOS'` + `cd cloudflare-worker && npm test`.

**Spec reference:** `docs/superpowers/specs/2026-05-24-macos-port-design.md` §2 (Mac voice calling) + §5 (signing, APNs) + §7 M3 milestone (line 332). Out of scope: M4 submission prep, screenshots, ASC enablement.

**Predecessors:** M0 → M2 (PR #57). M3 is gated on #57 being merged into main.

**Investigation findings (synthesized from 3 parallel plan candidates):**

### Existing infrastructure (audit-confirmed in 3 parallel reads)

- `PeerDropKit/Sources/PeerDropPlatform/CallProvider.swift` — clean async protocol with `CallEndReason` enum + explicit doc note that `configureAudioSession()` is macOS no-op. **Zero changes needed.**
- `PeerDropKit/Sources/PeerDropTransport/Voice/VoiceCallManager.swift` — provider-agnostic. **Zero changes.**
- `PeerDropKit/Sources/PeerDropCore/ConnectionManager.swift:514` — `configureVoiceCalling(callProvider:)` is the single injection point (mirror of iOS wire-up at `PeerDrop/App/PeerDropApp.swift:108`).
- `PeerDropKit/Sources/PeerDropCore/PushNotificationManager.swift:114` — hardcoded `"platform": "ios"` is the only iOS-coupled line.
- `cloudflare-worker/src/index.ts:1024` — `if (info.platform !== "ios" ...)` short-circuit suppresses Mac pushes today. Same JWT-signed APNs HTTP/2 path serves Mac (no new key needed).
- `cloudflare-worker/src/index.ts:962-973` — `/v2/device/register` already accepts `platform` field. Storage is already plumbed.
- `PeerDropMac/Adapters/VoiceFeatureFlag.swift` — `MacFeatureFlags.isVoiceUIAvailable: Bool { false }`. M3 flips to `true`.
- `project.yml:126` — `Voice/**` + `Settings/PushStatusRow.swift` excluded from PeerDropMac. M3 un-excludes both.
- `PeerDropMac/Adapters/MacPlatformDependencies.swift:19` — currently registers pasteboard/deviceName/systemInfo. M3 adds `callProvider`, `remoteNotifications`, `audioSession`, `platformIdentifier`.

### Open architectural decisions (locked in via 3-plan consensus)

1. **DND fidelity** — Accept the compromise: `UNUserNotificationCenter.notificationSettings()` for app-level mute. macOS 14 doesn't expose Focus state directly; we don't invest in heuristics. Panel always appears; only ringtone silenced. Spec §0 line 9 + §2 line 87 sanction this trade-off.
2. **Worker route shape** — New endpoint `/v2/call/:deviceId` (Plan B), separate from `/v2/invite/:deviceId`. Avoids future `inviteKind` mode-switch confusion at the chat-invite path. Both endpoints use the same `device:{id}` KV read for platform routing.
3. **Cold-launch grace window** — When APNs wakes a fully-terminated Mac, the WebSocket relay isn't connected yet; in-band `callRequest` over TCP can't arrive immediately. `MacCallProvider` shows the panel from the push payload alone and buffers Accept for up to 10 seconds while `InboxService.connect()` + `ConnectionManager` reconnect deliver the SDP offer. After 10s with no SDP, treat as call failure with reason `.unanswered`.
4. **Mac bundle ID** — `com.hanfour.peerdrop.mac` (already set in `project.yml` by M2). Worker uses `APNS_BUNDLE_ID_MAC` binding (defaults to `com.hanfour.peerdrop.mac`) for `apns-topic`.
5. **Ringtone source** — Bundled custom CAF (~5s loopable). Generation step: `afconvert -d aac -f caff Source.aiff PeerDropMac/Resources/Ringtone.caf`. Source asset to be commissioned or derived from CC0 (e.g. Freesound) — flagged for human action before Task 7. **NOT** a system sound (sandboxed apps can't reference `/System/Library/Sounds/`).
6. **PushKit divergence** — iOS keeps using PushKit (CallKit requirement). Mac is alert-push only. Documented in `MacCallProvider.swift` header.

### Plan-B's grace-window mechanism

Cold-launch flow (Mac is fully terminated when iPhone places call):
1. iPhone client posts `/v2/call/:macDeviceId` to Worker (this PR's Task 2).
2. Worker pushes APNs alert with payload `{ aps: { alert: { title: "Incoming call", body: callerName }, sound: "default" }, type: "callRequest", callerName, callerId }` + `apns-priority: 10`, `apns-expiration: now+30`.
3. macOS shows the alert in Notification Center; user taps → app launches.
4. `MacAppDelegate.application(_:didReceiveRemoteNotification:)` parses payload; if `userInfo["type"] == "callRequest"`, calls `MacCallProvider.handleColdLaunchPush(payload:)`.
5. `MacCallProvider` immediately shows the incoming panel with `callerName` from the push (no SDP yet).
6. In parallel, `ConnectionManager` reconnects to relay; `InboxService` re-establishes WebSocket; the iPhone's in-band `callRequest` PeerMessage arrives within ~3-8s with the SDP offer.
7. User taps Accept on the panel → `MacCallProvider` waits up to 10s for the SDP. If it arrives → normal answer flow. If 10s elapses → close panel + show banner "Call expired".

This avoids a race where the user accepts before SDP arrives and gets a confusingly silent call.

---

## File Structure

**New — PeerDropMac/Voice/** (un-excluded directory, entirely new code):
- `PeerDropMac/Voice/MacCallProvider.swift` — `CallProvider` impl, owns both window controllers + ringer + DND filter + 30s timer + cold-launch grace
- `PeerDropMac/Voice/MacIncomingCallPanel.swift` — `NSPanel` subclass + `NSWindowController`; 380×140 borderless floating, `.canJoinAllSpaces | .stationary | .ignoresCycle`
- `PeerDropMac/Voice/MacActiveCallWindow.swift` — `NSWindowController` for in-call; regular `NSWindow` 360×480, `.floating`, `.canJoinAllSpaces`
- `PeerDropMac/Voice/IncomingCallPanelView.swift` — SwiftUI: avatar + name + Accept/Decline + remaining-time indicator
- `PeerDropMac/Voice/MacVoiceCallView.swift` — macOS-tuned active-call UI (mute + end; no speaker toggle — macOS user controls system output)
- `PeerDropMac/Voice/MacRingtonePlayer.swift` — `AVAudioPlayer(numberOfLoops: -1)` with fade-out + silent mode
- `PeerDropMac/Voice/DNDFilter.swift` — `static func shouldSilenceRingtone() async -> Bool`
- `PeerDropMac/Voice/IncomingCallAutoDismissTimer.swift` — 30s `Task` wrapper with cancellation

**New — PeerDropMac/Adapters/**:
- `PeerDropMac/Adapters/MacRemoteNotificationRegistering.swift` — calls `NSApplication.shared.registerForRemoteNotifications()`
- `PeerDropMac/Adapters/MacAudioSession.swift` — `AudioSessionConfiguring`; `AVCaptureDevice.requestAccess(for: .audio)` for mic permission

**New — Resources**:
- `PeerDropMac/Resources/Ringtone.caf` — ~5s loopable, mono 44.1 kHz (commissioned / CC0-derived)

**New — Worker**:
- `cloudflare-worker/src/__tests__/macPlatformRouting.test.ts` — unit tests for `/v2/call/:deviceId` + topic routing

**Modify**:
- `PeerDropMac/Adapters/VoiceFeatureFlag.swift` — flag → `true`
- `PeerDropMac/Adapters/MacPlatformDependencies.swift` — register 4 new factories (`callProvider`, `remoteNotifications`, `audioSession`, `platformIdentifier`)
- `PeerDropMac/App/MacAppDelegate.swift` — 3 APNs callbacks + `MacCallProvider.handleColdLaunchPush(payload:)` routing + `UNUserNotificationCenter.delegate` conformance for `willPresent`
- `PeerDropMac/App/PeerDropMacApp.swift` — wire `MacCallProvider` to `ConnectionManager.configureVoiceCalling(_:)` in `.onAppear`; kick `PushNotificationManager.shared.requestAuthorizationAndRegister()`
- `PeerDropMac/App/PeerDrop-Mac.entitlements` — `<key>aps-environment</key><string>development</string>` (release xcconfig override flips to `production`) + `com.apple.security.device.audio-input`
- `PeerDropMac/App/Info.plist` — `NSMicrophoneUsageDescription`
- `project.yml` — drop `Voice/**` + `Settings/PushStatusRow.swift` from PeerDropMac excludes; add `Resources/**` resource entry
- `PeerDropKit/Sources/PeerDropCore/PushNotificationManager.swift` — replace hardcoded `"platform": "ios"` with `PlatformDependencies.shared.platformIdentifier()`
- `PeerDropKit/Sources/PeerDropPlatform/PlatformDependencies.swift` — new `platformIdentifier: () -> String` factory (default `"ios"` on `canImport(UIKit)`, else `"macos"`)
- `cloudflare-worker/src/apns.ts` — accept optional `topicOverride: string`, `priority: number`, `expiration: number`
- `cloudflare-worker/src/index.ts` — add `/v2/call/:deviceId POST` route; per-platform topic selection in both `/v2/invite/` and `/v2/call/`; lazy default for missing `platform` field
- `cloudflare-worker/wrangler.toml` — declare `APNS_BUNDLE_ID_MAC` binding

---

## Task 1: Pre-M3 audit

**Files:** (analysis only, no commits)

Goal: verify the prerequisites + lock in API shapes before any implementer dispatch.

- [ ] **Step 1: Verify M2 merged**

```bash
git log --oneline main | head -5            # confirm M2 commits present
gh pr view 57 --json state -q .state         # expect MERGED
```

If not merged, STOP and escalate.

- [ ] **Step 2: Verify `swift build` clean on macOS**

```bash
cd PeerDropKit && swift build 2>&1 | tail -3 && cd ..
```

Confirms all 6 modules compile on the macOS host toolchain.

- [ ] **Step 3: Audit Worker `/v2/invite/:deviceId` + KV shape**

Read `cloudflare-worker/src/index.ts` lines 962-1050. Confirm:
- `/v2/device/register` body shape (deviceId, pushToken, platform)
- KV write at `device:${deviceId}`
- `/v2/invite/:deviceId` reads KV + branches on `info.platform`
- `apns.ts` `sendAPNs(...)` signature

Document any drift from the plan's assumed shape.

- [ ] **Step 4: Verify NSWindow / NSPanel API surface for Xcode 26 / macOS 14**

Confirm via Apple Docs (or `xcrun --sdk macosx --show-sdk-path` + headers):
- `NSPanel(contentRect:styleMask:backing:defer:)` exists
- `.collectionBehavior` accepts `.canJoinAllSpaces | .stationary | .ignoresCycle`
- `.nonactivatingPanel` style mask preserves "doesn't activate app" behavior
- `NSVisualEffectView.Material.hudWindow` exists (might be deprecated → fallback to `.fullScreenUI`)
- `NSWindow.collectionBehavior` for active-call window with `.fullScreenAuxiliary` allowed

- [ ] **Step 5: Verify mount order — `MacAppDelegate` callbacks and `ConnectionManager` availability**

Read `PeerDropMac/App/MacAppDelegate.swift` + `PeerDropMacApp.swift`. Confirm:
- `applicationDidFinishLaunching` runs BEFORE first scene render → safe to set up `MacCallProvider` instance
- `connectionManager` weak ref set in `PeerDropMacApp.onAppear` after main scene appears → `configureVoiceCalling(_:)` call must be in `.onAppear`, not `applicationDidFinishLaunching`
- `UNUserNotificationCenter.current().delegate` can be set in `applicationDidFinishLaunching` without timing issues

- [ ] **Step 6: Confirm Mac bundle ID**

```bash
grep "PRODUCT_BUNDLE_IDENTIFIER" project.yml
```

Expected: `com.hanfour.peerdrop.mac` on the PeerDropMac target. If different, Worker `APNS_BUNDLE_ID_MAC` default needs to change.

- [ ] **Step 7: Audit `VoiceCallView` for macOS compatibility**

After `Voice/**` un-exclude, `VoiceCallView` enters the macOS target. Read it (`PeerDrop/UI/Voice/VoiceCallView.swift`) — flag iOS-only API (`Color(.systemFill)`, `.navigationBarTitleDisplayMode`, etc.). Decide:
- (a) `#if os(macOS)` color shims in-place + add to surface-level gate list (extend M2 Task 6a pattern)
- (b) Write fresh `MacVoiceCallView` and exclude the iOS one

Default: (b) — Task 10 ships a Mac-bespoke view.

- [ ] **Step 8: Report findings**

```
## M3 audit (2026-06-06)

### Prerequisites
- M2 merged (#57): YES/NO
- PeerDropKit macOS swift build: YES/NO

### Worker API shape
- /v2/device/register body: { deviceId, pushToken, platform }   (confirmed/drift: …)
- KV write: device:${id} → { pushToken, platform }              (confirmed/drift: …)
- /v2/invite/:deviceId reads KV (line N), branches on platform (line N)
- apns.ts sendAPNs signature: …

### NSPanel / NSWindow API
- NSPanel init exists: YES/NO
- .nonactivatingPanel mask supported: YES/NO
- .canJoinAllSpaces | .stationary supported: YES/NO
- NSVisualEffectView.Material.hudWindow: AVAILABLE/DEPRECATED (fallback: …)

### Mount order
- MacAppDelegate.applicationDidFinishLaunching runs pre-scene: YES/NO
- ConnectionManager wired in PeerDropMacApp.onAppear: confirmed at line N
- Decision: configureVoiceCalling(_:) called in .onAppear (not applicationDidFinishLaunching)

### Bundle ID
- Mac: com.hanfour.peerdrop.mac (confirmed)
- iOS: com.hanfour.peerdrop (confirmed)

### VoiceCallView macOS compatibility
- iOS-only APIs: <list>
- Decision: write Mac-bespoke MacVoiceCallView (Task 10)

### Anomalies / plan deviations
- <list, or "none">

### Recommendation
- Plan is accurate; proceed with Tasks 2-13 as written / Plan needs adjustment: …
```

**No commits.** Report only.

---

## Task 2: Worker — `/v2/call/:deviceId` + per-platform APNs routing

**Files:**
- Modify: `cloudflare-worker/src/index.ts`
- Modify: `cloudflare-worker/src/apns.ts`
- Modify: `cloudflare-worker/wrangler.toml`
- Create: `cloudflare-worker/src/__tests__/macPlatformRouting.test.ts`

- [ ] **Step 1: Extend `apns.ts` `sendAPNs(...)` signature**

Accept optional:
- `topicOverride?: string` — replaces `config.bundleId` for `apns-topic` header
- `priority?: number` — `apns-priority` (default 10)
- `expiration?: number` — `apns-expiration` Unix timestamp (default 0 / no expiry)
- `interruptionLevel?: "active" | "time-sensitive" | "critical"` — emits `aps["interruption-level"]`

Wire each through to the HTTP/2 headers + payload.

- [ ] **Step 2: Add `APNS_BUNDLE_ID_MAC` env binding**

In `wrangler.toml`, declare:
```toml
[vars]
APNS_BUNDLE_ID_MAC = "com.hanfour.peerdrop.mac"
```

Add the corresponding TypeScript type to `Env` interface in `index.ts`.

- [ ] **Step 3: Add `/v2/call/:deviceId POST` route**

```typescript
// New route: voice-call wake push
router.post("/v2/call/:deviceId", async (request, params, env) => {
  const { callerId, callerName } = await request.json<{ callerId: string; callerName: string }>();
  const deviceId = params.deviceId;
  const info = await env.V2_STORE.get(`device:${deviceId}`, "json") as DeviceInfo | null;
  if (!info?.pushToken) return new Response("not_registered", { status: 404 });

  const platform = info.platform ?? "ios"; // lazy default
  const topic = platform === "macos"
    ? env.APNS_BUNDLE_ID_MAC
    : env.APNS_BUNDLE_ID;

  const payload = {
    aps: {
      alert: { title: "Incoming call", body: callerName },
      sound: "default",
      "interruption-level": "time-sensitive",
    },
    type: "callRequest",
    callerId,
    callerName,
  };

  return sendAPNs({
    env,
    deviceToken: info.pushToken,
    payload,
    topicOverride: topic,
    priority: 10,
    expiration: Math.floor(Date.now() / 1000) + 30,
  });
});
```

- [ ] **Step 4: Update `/v2/invite/:deviceId` to honor `platform` field**

Replace the `if (info.platform !== "ios" || !env.APNS_KEY_P8)` short-circuit at ~line 1024 with per-platform topic selection (same pattern as Step 3 but for chat invites — keep existing `aps.alert` shape, just swap topic).

Lazy default: missing `platform` field treated as `"ios"`.

- [ ] **Step 5: Add unit tests**

`cloudflare-worker/src/__tests__/macPlatformRouting.test.ts`:
- Test 1: iOS device gets `apns-topic: com.hanfour.peerdrop` (existing behavior unchanged)
- Test 2: macOS device on `/v2/call/` gets `apns-topic: com.hanfour.peerdrop.mac` + `interruption-level: time-sensitive`
- Test 3: macOS device on `/v2/invite/` gets Mac topic with chat-shaped payload
- Test 4: Missing `APNS_KEY_P8` env → returns `not_configured` regardless of platform
- Test 5: Missing `platform` field → defaults to iOS

Use the existing test scaffolding pattern in `cloudflare-worker/src/__tests__/`.

- [ ] **Step 6: Run tests**

```bash
cd cloudflare-worker && npm test -- macPlatformRouting
```

Expected: 5/5 pass.

- [ ] **Step 7: Commit**

```bash
git add cloudflare-worker/
git commit -m "$(cat <<'EOF'
feat(worker): /v2/call route + per-platform APNs routing for M3

Adds the Mac voice-call wake-push endpoint /v2/call/:deviceId with
time-sensitive alert payload + 30s expiration. /v2/invite gains
per-platform topic selection (com.hanfour.peerdrop.mac for macOS
devices). Lazy default: missing `platform` field treated as iOS for
backward compat with v5.3 devices that never sent the field.

apns.ts sendAPNs() now accepts topicOverride / priority / expiration /
interruptionLevel parameters. wrangler.toml declares APNS_BUNDLE_ID_MAC.

5 unit tests cover both routes × both platforms + edge cases.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: `PlatformDependencies.platformIdentifier` injection + `PushNotificationManager` platform-aware

**Files:**
- Modify: `PeerDropKit/Sources/PeerDropPlatform/PlatformDependencies.swift`
- Modify: `PeerDropKit/Sources/PeerDropCore/PushNotificationManager.swift`
- Modify: existing `PeerDropPlatformTests` to cover the new factory

- [ ] **Step 1: Add `platformIdentifier` factory**

In `PeerDropKit/Sources/PeerDropPlatform/PlatformDependencies.swift`:

```swift
public var platformIdentifier: () -> String

// In init:
platformIdentifier: (() -> String)? = nil,

// Factory wiring:
self.platformIdentifier = platformIdentifier ?? { PlatformDependencies.makePlatformIdentifier() }

// New static factory:
private static func makePlatformIdentifier() -> String {
    #if canImport(UIKit)
    return "ios"
    #elseif os(macOS)
    return "macos"
    #else
    return "unknown"
    #endif
}
```

- [ ] **Step 2: Generalize `PushNotificationManager`**

In `PeerDropKit/Sources/PeerDropCore/PushNotificationManager.swift:114`, replace the hardcoded `"platform": "ios"` with:

```swift
"platform": PlatformDependencies.shared.platformIdentifier()
```

Add `import PeerDropPlatform` if not already present.

- [ ] **Step 3: Add unit test**

In `PeerDropKit/Tests/PeerDropPlatformTests/`:

```swift
func test_platformIdentifier_defaultsToOSAppropriate() {
    let id = PlatformDependencies.shared.platformIdentifier()
    #if canImport(UIKit)
    XCTAssertEqual(id, "ios")
    #elseif os(macOS)
    XCTAssertEqual(id, "macos")
    #endif
}
```

In `PeerDropCoreTests/`:

```swift
func test_pushManagerSendsCorrectPlatformInBody() async throws {
    // Use injected MockPlatformDependencies setting platformIdentifier to "macos"
    // Capture the URLRequest body; assert JSON contains "platform":"macos"
}
```

(See `PeerDropTests/MockPlatformDependencies*Tests.swift` for the existing mock pattern.)

- [ ] **Step 4: Build + test**

```bash
cd PeerDropKit && swift test --filter PlatformIdentifierTests 2>&1 | tail -3 && cd ..
xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' 2>&1 | grep "Executed " | tail -2
```

Expected: new tests pass; iOS 635 baseline preserved.

- [ ] **Step 5: Commit**

```bash
git add PeerDropKit/
git commit -m "$(cat <<'EOF'
feat(kit): inject platformIdentifier for cross-platform push registration

PushNotificationManager's device-register payload now reads
PlatformDependencies.shared.platformIdentifier() instead of the
hardcoded "ios" literal. Default identifier resolves via #if guards:
"ios" on canImport(UIKit), "macos" on os(macOS), "unknown" otherwise
(visionOS forward-compat).

Worker (#PR-N) reads the platform field for APNs topic routing.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Mac entitlements + Info.plist

**Files:**
- Modify: `PeerDropMac/App/PeerDrop-Mac.entitlements`
- Modify: `PeerDropMac/App/Info.plist`

- [ ] **Step 1: Add APNs + microphone entitlements**

In `PeerDropMac/App/PeerDrop-Mac.entitlements`:

```xml
<!-- APNs alert push for M3 voice -->
<key>aps-environment</key>
<string>development</string>

<!-- Microphone access for voice calls -->
<key>com.apple.security.device.audio-input</key>
<true/>
```

Note: `aps-environment` flips to `production` via xcconfig override at release-build time. For M3 dev work, `development` is correct (uses Apple's sandbox APNs servers).

- [ ] **Step 2: Add microphone usage description**

In `PeerDropMac/App/Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>PeerDrop uses your microphone for peer-to-peer voice calls.</string>
```

- [ ] **Step 3: Verify**

```bash
plutil -lint PeerDropMac/App/PeerDrop-Mac.entitlements
plutil -lint PeerDropMac/App/Info.plist
xcodegen generate 2>&1 | tail -3
xcodebuild build -scheme PeerDropMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
```

Expected: `BUILD SUCCEEDED`. (Code signing disabled for build verify; APNs entitlement only matters at runtime with signed builds.)

- [ ] **Step 4: Commit**

```bash
git add PeerDropMac/App/PeerDrop-Mac.entitlements PeerDropMac/App/Info.plist PeerDrop.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
feat(m3): add APNs + microphone entitlements for Mac voice

aps-environment = development (release config flips to production via
xcconfig override).
com.apple.security.device.audio-input + NSMicrophoneUsageDescription
for AVCaptureDevice.requestAccess(for: .audio).

These are runtime-relevant only — build verify uses CODE_SIGNING_ALLOWED=NO.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: `MacRemoteNotificationRegistering` adapter + MacAppDelegate APNs callbacks

**Files:**
- Create: `PeerDropMac/Adapters/MacRemoteNotificationRegistering.swift`
- Modify: `PeerDropMac/App/MacAppDelegate.swift`
- Modify: `PeerDropMac/Adapters/MacPlatformDependencies.swift`

- [ ] **Step 1: Create the adapter**

```swift
// PeerDropMac/Adapters/MacRemoteNotificationRegistering.swift
#if canImport(AppKit)
import AppKit
import PeerDropPlatform

@MainActor
final class MacRemoteNotificationRegistering: RemoteNotificationRegistering {
    func registerForRemoteNotifications() {
        NSApplication.shared.registerForRemoteNotifications()
    }
}
#endif
```

- [ ] **Step 2: Register in `MacPlatformDependencies.register()`**

```swift
PlatformDependencies.shared.remoteNotifications = { MacRemoteNotificationRegistering() }
PlatformDependencies.shared.platformIdentifier = { "macos" }
```

(The `platformIdentifier` factory already defaults to `"macos"` via `#if os(macOS)` in Task 3 — this explicit registration is for clarity + future override flexibility.)

- [ ] **Step 3: Add 3 APNs callbacks to `MacAppDelegate`**

```swift
// MacAppDelegate.swift additions

func application(
    _ application: NSApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
) {
    logger.info("APNs token received: \(deviceToken.map { String(format: "%02x", $0) }.joined())")
    Task { @MainActor in
        await PushNotificationManager.shared.handleDeviceToken(deviceToken)
    }
}

func application(
    _ application: NSApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
) {
    logger.error("APNs registration failed: \(error.localizedDescription)")
    Task { @MainActor in
        PushNotificationManager.shared.handleRegistrationFailure(error)
    }
}

func application(
    _ application: NSApplication,
    didReceiveRemoteNotification userInfo: [String: Any]
) {
    logger.info("APNs push received: type=\(userInfo["type"] as? String ?? "unknown")")
    // Task 11 routes callRequest payloads to MacCallProvider.
    // For Task 5, just log.
}
```

- [ ] **Step 4: Kick push registration on launch**

In `PeerDropMacApp.swift` `.onAppear`:

```swift
.onAppear {
    appDelegate.connectionManager = connectionManager
    Task {
        await PushNotificationManager.shared.requestAuthorizationAndRegister()
    }
}
```

- [ ] **Step 5: Build verify**

```bash
xcodegen generate 2>&1 | tail -3
xcodebuild build -scheme PeerDropMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' 2>&1 | tail -3
```

Expected: both `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
git add PeerDropMac/ PeerDrop.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
feat(m3): macOS APNs registration adapter + AppDelegate callbacks

  - MacRemoteNotificationRegistering wraps
    NSApplication.shared.registerForRemoteNotifications()
  - MacAppDelegate implements didRegisterForRemoteNotificationsWithDeviceToken,
    didFailToRegister, didReceiveRemoteNotification — forwards token to
    PushNotificationManager.shared.handleDeviceToken
  - MacPlatformDependencies.register() wires the adapter +
    platformIdentifier = "macos"
  - PeerDropMacApp.onAppear kicks
    PushNotificationManager.requestAuthorizationAndRegister()
    (matches iOS PeerDropApp pattern)

didReceiveRemoteNotification is wire-only in this commit — Task 11's
MacCallProvider integration routes callRequest payloads.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: `MacAudioSession` adapter

**Files:**
- Create: `PeerDropMac/Adapters/MacAudioSession.swift`
- Modify: `PeerDropMac/Adapters/MacPlatformDependencies.swift`

- [ ] **Step 1: Implement adapter**

```swift
// PeerDropMac/Adapters/MacAudioSession.swift
#if canImport(AppKit)
import AVFoundation
import PeerDropPlatform

@MainActor
final class MacAudioSession: AudioSessionConfiguring {
    var recordPermissionGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func requestRecordPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func activate(_ mode: AudioSessionMode) throws {
        // WebRTC manages voice-chat routing on macOS internally — no-op.
    }

    func deactivate() throws { /* no-op */ }
    func overrideOutputToSpeaker(_ override: Bool) throws { /* no-op */ }
}
#endif
```

(Inspect `AudioSessionConfiguring` to confirm the actual method signatures — adapt as needed.)

- [ ] **Step 2: Register**

In `MacPlatformDependencies.register()`:

```swift
PlatformDependencies.shared.audioSession = { MacAudioSession() }
```

- [ ] **Step 3: Build verify + commit**

```bash
xcodegen generate 2>&1 | tail -3
xcodebuild build -scheme PeerDropMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
git add PeerDropMac/
git commit -m "feat(m3): macOS AVCaptureDevice-backed AudioSessionConfiguring

WebRTC self-manages voice-chat routing on macOS; activate/deactivate/
overrideOutputToSpeaker are no-ops. requestRecordPermission wraps
AVCaptureDevice.requestAccess(for: .audio) for mic prompt parity with
iOS.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Bundled ringtone + `MacRingtonePlayer`

**Files:**
- Create: `PeerDropMac/Resources/Ringtone.caf`
- Create: `PeerDropMac/Voice/MacRingtonePlayer.swift`
- Modify: `project.yml` (add Resources/ to PeerDropMac sources)

- [ ] **Step 1: Source the ringtone asset**

**Human action required** — supply `Ringtone.caf`. Options:
- Commission a short branded ring (~5s, AAC-in-CAF, ~50 KB).
- Use a CC0 source (e.g. Freesound):
  ```bash
  # Example transform from an .aiff:
  afconvert -d aac -f caff PathToSource.aiff PeerDropMac/Resources/Ringtone.caf
  ```

Loopable, mono, 44.1 kHz, max 6s, ~50 KB target. Sandboxed apps can't reference `/System/Library/Sounds/` so bundling is mandatory.

- [ ] **Step 2: Implement `MacRingtonePlayer`**

```swift
// PeerDropMac/Voice/MacRingtonePlayer.swift
#if canImport(AppKit)
import AVFoundation
import os.log

@MainActor
final class MacRingtonePlayer {
    private let logger = Logger(subsystem: "com.hanfour.peerdrop.mac", category: "Ringtone")
    private var player: AVAudioPlayer?

    init() {
        guard let url = Bundle.main.url(forResource: "Ringtone", withExtension: "caf") else {
            logger.error("Ringtone.caf not found in bundle")
            return
        }
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.numberOfLoops = -1
            player?.prepareToPlay()
        } catch {
            logger.error("Failed to init ringtone: \(error.localizedDescription)")
        }
    }

    /// `silent: true` is the DND mode — still call play() so timing semantics
    /// are uniform (timer, panel, etc.) but with zero volume.
    func start(silent: Bool = false) {
        guard let player else { return }
        player.volume = silent ? 0 : 1
        player.currentTime = 0
        player.play()
    }

    func stop(fadeOut: TimeInterval = 0.2) {
        guard let player = player, player.isPlaying else { return }
        if fadeOut > 0 {
            player.setVolume(0, fadeDuration: fadeOut)
            Task { @MainActor [weak player] in
                try? await Task.sleep(for: .seconds(fadeOut))
                player?.stop()
            }
        } else {
            player.stop()
        }
    }
}
#endif
```

- [ ] **Step 3: Add `Resources/` to project.yml**

Inside the PeerDropMac sources block:

```yaml
- path: PeerDropMac/Resources
```

This bundles the .caf as a copy-files build phase.

- [ ] **Step 4: Build + commit**

```bash
xcodegen generate
xcodebuild build -scheme PeerDropMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
git add PeerDropMac/ project.yml PeerDrop.xcodeproj/project.pbxproj
git commit -m "feat(m3): bundled Ringtone.caf + MacRingtonePlayer

AVAudioPlayer with numberOfLoops = -1 + fade-out stop. silent: true
flag for DND mode (volume = 0 but still plays so the panel + timer
semantics stay uniform).

Sandboxed apps can't reference /System/Library/Sounds, so the .caf
is bundled in Resources/.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: `DNDFilter`

**Files:**
- Create: `PeerDropMac/Voice/DNDFilter.swift`

- [ ] **Step 1: Implement**

```swift
// PeerDropMac/Voice/DNDFilter.swift
#if canImport(AppKit)
import UserNotifications
import os.log

enum DNDFilter {
    private static let logger = Logger(subsystem: "com.hanfour.peerdrop.mac", category: "DND")

    /// Returns `true` when macOS is in a DND-equivalent state and ringtone
    /// audio should be muted. Panel still appears per spec §0 line 9.
    ///
    /// Limitation: macOS 14 doesn't expose Focus mode state publicly. This
    /// reads `UNUserNotificationCenter.notificationSettings()` only — sound
    /// disabled OR notification center disabled count as DND. Focus filters
    /// (Sleep, Do Not Disturb mode, custom Focus) aren't directly readable;
    /// document the trade-off in release notes.
    static func shouldSilenceRingtone() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let muted = settings.soundSetting == .disabled
            || settings.notificationCenterSetting == .disabled
        if muted {
            logger.info("DND active — ringtone silenced (panel still visible)")
        }
        return muted
    }
}
#endif
```

- [ ] **Step 2: Build + commit**

```bash
xcodegen generate
xcodebuild build -scheme PeerDropMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
git add PeerDropMac/Voice/DNDFilter.swift PeerDrop.xcodeproj/project.pbxproj
git commit -m "feat(m3): DND filter via UNUserNotificationCenter settings

shouldSilenceRingtone() reads UN settings; treats sound-disabled OR
center-disabled as DND. Panel still appears per spec §0 line 9 —
this only mutes the AVAudioPlayer.

Known limitation: macOS 14 doesn't expose Focus mode state publicly,
so per-Focus configurations aren't detectable. Will document in
release notes.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: `MacIncomingCallPanel` (NSPanel-backed)

**Files:**
- Create: `PeerDropMac/Voice/MacIncomingCallPanel.swift`
- Create: `PeerDropMac/Voice/IncomingCallPanelView.swift`
- Create: `PeerDropMac/Voice/IncomingCallAutoDismissTimer.swift`

- [ ] **Step 1: `IncomingCallAutoDismissTimer`**

```swift
// PeerDropMac/Voice/IncomingCallAutoDismissTimer.swift
#if canImport(AppKit)
import Foundation

@MainActor
final class IncomingCallAutoDismissTimer {
    private var task: Task<Void, Never>?

    func start(duration: TimeInterval = 30, onFire: @escaping @MainActor () -> Void) {
        cancel()
        task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            onFire()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
#endif
```

- [ ] **Step 2: `IncomingCallPanelView` (SwiftUI)**

```swift
// PeerDropMac/Voice/IncomingCallPanelView.swift
#if canImport(AppKit)
import SwiftUI

struct IncomingCallPanelView: View {
    let callerName: String
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Incoming call")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(callerName)
                    .font(.headline)
            }
            Spacer()
            HStack(spacing: 8) {
                Button(action: onDecline) {
                    Image(systemName: "phone.down.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(.red, in: Circle())
                }
                .buttonStyle(.plain)
                Button(action: onAccept) {
                    Image(systemName: "phone.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(.green, in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 380, height: 80)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
#endif
```

- [ ] **Step 3: `MacIncomingCallPanel` (NSPanel-backed window controller)**

```swift
// PeerDropMac/Voice/MacIncomingCallPanel.swift
#if canImport(AppKit)
import AppKit
import SwiftUI

@MainActor
final class MacIncomingCallPanel {
    private var panel: NSPanel?

    func show(
        callerName: String,
        onAccept: @escaping () -> Void,
        onDecline: @escaping () -> Void
    ) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 100),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false

        let view = IncomingCallPanelView(
            callerName: callerName,
            onAccept: onAccept,
            onDecline: onDecline
        )
        panel.contentView = NSHostingView(rootView: view)

        // Position top-right of the main screen, ~80pt from top + right edges
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: frame.maxX - 380 - 20,
                y: frame.maxY - 100 - 80
            ))
        }

        panel.orderFrontRegardless()  // shows without activating app
        self.panel = panel
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}
#endif
```

Key design points:
- `NSPanel` + `.nonactivatingPanel` = doesn't bring PeerDrop to foreground (FaceTime behavior).
- `.canJoinAllSpaces | .stationary` = stays visible when user switches Spaces; position relative to screen, not relative to current Space.
- `.fullScreenAuxiliary` = appears even when user is in a full-screen app.
- `orderFrontRegardless()` = shows even if PeerDrop isn't the active app.

- [ ] **Step 4: Build verify**

```bash
xcodegen generate
xcodebuild build -scheme PeerDropMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
```

(No smoke test yet — wired up in Task 11.)

- [ ] **Step 5: Commit**

```bash
git add PeerDropMac/Voice/ PeerDrop.xcodeproj/project.pbxproj
git commit -m "feat(m3): incoming-call NSPanel (floating, cross-Space)

NSPanel + .nonactivatingPanel — doesn't bring PeerDrop to foreground
(FaceTime behavior). .canJoinAllSpaces | .stationary follows across
Spaces, .fullScreenAuxiliary shows over full-screen apps,
orderFrontRegardless() displays without app activation.

380×100 borderless panel hosting IncomingCallPanelView via NSHostingView;
.regularMaterial background. Top-right anchored to NSScreen.main.

IncomingCallAutoDismissTimer wraps the 30s Task.sleep with cancellation.
Wiring lives in MacCallProvider (Task 11).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: `MacActiveCallWindow` + `MacVoiceCallView`

**Files:**
- Create: `PeerDropMac/Voice/MacActiveCallWindow.swift`
- Create: `PeerDropMac/Voice/MacVoiceCallView.swift`

- [ ] **Step 1: `MacVoiceCallView`**

Bespoke Mac call view (audit Task 1 Step 7 decided not to reuse iOS `VoiceCallView`). Minimal:

```swift
// PeerDropMac/Voice/MacVoiceCallView.swift
#if canImport(AppKit)
import SwiftUI
import PeerDropCore
import PeerDropTransport

struct MacVoiceCallView: View {
    @EnvironmentObject var voiceCallManager: VoiceCallManager
    let peerName: String

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.tint)

            Text(peerName)
                .font(.title2)

            Text(voiceCallManager.isInCall ? "Connected" : "Connecting…")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            HStack(spacing: 24) {
                Button {
                    voiceCallManager.isMuted.toggle()
                } label: {
                    Image(systemName: voiceCallManager.isMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.title)
                        .frame(width: 56, height: 56)
                        .background(voiceCallManager.isMuted ? .red : .secondary.opacity(0.2), in: Circle())
                        .foregroundStyle(voiceCallManager.isMuted ? .white : .primary)
                }
                .buttonStyle(.plain)
                .help(voiceCallManager.isMuted ? "Unmute" : "Mute")

                Button {
                    voiceCallManager.endCall()
                } label: {
                    Image(systemName: "phone.down.fill")
                        .font(.title)
                        .frame(width: 56, height: 56)
                        .background(.red, in: Circle())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .help("End call")
            }
            .padding(.bottom, 40)
        }
        .padding(.top, 40)
        .frame(width: 320, height: 420)
    }
}
#endif
```

Note: assumes `VoiceCallManager` exposes `isInCall: Bool` and `isMuted: Bool` and `endCall()`. Verify against actual API; adapt if signatures differ. No speaker toggle (macOS user controls system output).

- [ ] **Step 2: `MacActiveCallWindow`**

```swift
// PeerDropMac/Voice/MacActiveCallWindow.swift
#if canImport(AppKit)
import AppKit
import SwiftUI
import PeerDropTransport

@MainActor
final class MacActiveCallWindow {
    private var window: NSWindow?

    func show(peerName: String, voiceCallManager: VoiceCallManager) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Call with \(peerName)"
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.center()

        window.contentView = NSHostingView(
            rootView: MacVoiceCallView(peerName: peerName)
                .environmentObject(voiceCallManager)
        )

        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func dismiss() {
        window?.orderOut(nil)
        window = nil
    }
}
#endif
```

- [ ] **Step 3: Build + commit**

```bash
xcodegen generate
xcodebuild build -scheme PeerDropMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
git add PeerDropMac/Voice/ PeerDrop.xcodeproj/project.pbxproj
git commit -m "feat(m3): active-call NSWindow + MacVoiceCallView

Floating + .canJoinAllSpaces NSWindow (regular style, not panel —
this one's allowed to take focus). MacVoiceCallView is Mac-bespoke:
mic + end buttons only; no speaker toggle (macOS user controls
output via system Volume).

Voice/** un-exclude still pending — VoiceCallView stays iOS-only;
this Mac view talks to VoiceCallManager directly.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 11: `MacCallProvider` core (integrates 5-10 + cold-launch grace)

**Files:**
- Create: `PeerDropMac/Voice/MacCallProvider.swift`
- Modify: `PeerDropMac/App/MacAppDelegate.swift` (route push payloads)

- [ ] **Step 1: Implement `MacCallProvider`**

```swift
// PeerDropMac/Voice/MacCallProvider.swift
#if canImport(AppKit)
import AppKit
import PeerDropPlatform
import PeerDropTransport
import os.log

@MainActor
final class MacCallProvider: NSObject, CallProvider {
    private let logger = Logger(subsystem: "com.hanfour.peerdrop.mac", category: "CallProvider")

    private let incomingPanel = MacIncomingCallPanel()
    private let activeWindow = MacActiveCallWindow()
    private let ringer = MacRingtonePlayer()
    private let dismissTimer = IncomingCallAutoDismissTimer()

    private var pendingColdLaunchCaller: String?
    private var coldLaunchGraceTask: Task<Void, Never>?

    var onAnswerCall: (() -> Void)?
    var onEndCall: ((CallEndReason) -> Void)?

    // MARK: - CallProvider

    func reportIncomingCall(from peerName: String) async throws {
        logger.info("Incoming call from \(peerName)")

        let silenced = await DNDFilter.shouldSilenceRingtone()
        ringer.start(silent: silenced)

        incomingPanel.show(
            callerName: peerName,
            onAccept: { [weak self] in self?.handleAccept() },
            onDecline: { [weak self] in self?.handleDecline() }
        )

        dismissTimer.start(duration: 30) { [weak self] in
            self?.handleTimeout()
        }
    }

    func startOutgoingCall(to peerName: String) {
        logger.info("Outgoing call to \(peerName)")
        // Active window will be configured via voiceCallManager injection
        // at the call site (PeerDropMacApp wiring).
    }

    func reportOutgoingCallConnected() {
        logger.info("Outgoing call connected")
        // MacVoiceCallView observes VoiceCallManager.isInCall — flips
        // automatically. No work here.
    }

    func reportCallEnded(reason: CallEndReason) {
        logger.info("Call ended: \(String(describing: reason))")
        cleanup()
    }

    func endCall() {
        logger.info("Local user ended call")
        cleanup()
    }

    func configureAudioSession() {
        // WebRTC handles voice-chat routing on macOS — no-op.
    }

    // MARK: - Cold-launch grace window

    /// Called by MacAppDelegate.application(_:didReceiveRemoteNotification:)
    /// when a callRequest push payload arrives. If the app is cold-launched,
    /// SDP from the in-band callRequest PeerMessage may take 3-10 seconds to
    /// arrive after the relay reconnects. We show the panel from the push
    /// payload alone; Accept is buffered for up to 10s.
    func handleColdLaunchPush(callerName: String) {
        logger.info("Cold-launch push: \(callerName) — starting 10s grace")
        pendingColdLaunchCaller = callerName

        Task {
            try? await reportIncomingCall(from: callerName)
        }

        coldLaunchGraceTask?.cancel()
        coldLaunchGraceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            // SDP didn't arrive in 10s — treat as expired
            self?.logger.warning("Cold-launch SDP grace expired; treating as unanswered")
            self?.reportCallEnded(reason: .unanswered)
            self?.pendingColdLaunchCaller = nil
        }
    }

    /// Called when the in-band callRequest PeerMessage arrives via the
    /// re-established TCP/relay channel. Cancels the grace timer.
    func handleInbandCallRequest(from peerName: String) {
        if pendingColdLaunchCaller != nil {
            logger.info("In-band SDP arrived during cold-launch grace — proceeding")
            coldLaunchGraceTask?.cancel()
            coldLaunchGraceTask = nil
            pendingColdLaunchCaller = nil
        }
        // Normal path: VoiceCallManager will call reportIncomingCall directly;
        // this handler is only for the cold-launch race.
    }

    // MARK: - Private

    private func handleAccept() {
        logger.info("User accepted call")
        ringer.stop()
        dismissTimer.cancel()
        coldLaunchGraceTask?.cancel()
        incomingPanel.dismiss()
        // activeWindow.show() is called by the VoiceCallManager wiring
        // (depends on connectionManager + currentPeer)
        onAnswerCall?()
    }

    private func handleDecline() {
        logger.info("User declined call")
        cleanup()
        onEndCall?(.declinedElsewhere)
    }

    private func handleTimeout() {
        logger.info("Call timed out (30s)")
        cleanup()
        onEndCall?(.unanswered)
    }

    private func cleanup() {
        ringer.stop()
        dismissTimer.cancel()
        coldLaunchGraceTask?.cancel()
        coldLaunchGraceTask = nil
        pendingColdLaunchCaller = nil
        incomingPanel.dismiss()
        activeWindow.dismiss()
    }
}
#endif
```

- [ ] **Step 2: Route push payloads in MacAppDelegate**

Update the `didReceiveRemoteNotification` callback from Task 5:

```swift
func application(
    _ application: NSApplication,
    didReceiveRemoteNotification userInfo: [String: Any]
) {
    logger.info("APNs push received: type=\(userInfo["type"] as? String ?? "unknown")")

    if userInfo["type"] as? String == "callRequest" {
        let callerName = userInfo["callerName"] as? String ?? "Unknown"
        Task { @MainActor in
            // Forward to MacCallProvider for cold-launch handling
            macCallProvider?.handleColdLaunchPush(callerName: callerName)
        }
    }
    // Other push types (chat invites, etc.) continue through existing paths.
}
```

(Add `var macCallProvider: MacCallProvider?` to `MacAppDelegate`. Set it in `applicationDidFinishLaunching` or via `PeerDropMacApp.onAppear`.)

- [ ] **Step 3: Build + commit**

```bash
xcodegen generate
xcodebuild build -scheme PeerDropMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
git add PeerDropMac/ PeerDrop.xcodeproj/project.pbxproj
git commit -m "feat(m3): MacCallProvider integrating panel + ringer + cold-launch grace

CallProvider conformance routes:
  - reportIncomingCall: starts DND-filtered ringer + shows panel +
    starts 30s auto-dismiss timer
  - Accept → cleanup + onAnswerCall callback
  - Decline → cleanup + onEndCall(.declinedElsewhere)
  - Timeout → cleanup + onEndCall(.unanswered)

handleColdLaunchPush: called by MacAppDelegate.didReceiveRemoteNotification
when type=callRequest. Starts 10s grace window for the in-band SDP via
re-established relay. handleInbandCallRequest cancels the grace timer
when the PeerMessage arrives (normal race-free path).

reportCallEnded(reason:) and endCall() both flow through cleanup() —
single teardown path for ringer + timer + grace + windows.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 12: Final wiring — `MacPlatformDependencies` + `PeerDropMacApp` + flag flip + un-excludes

**Files:**
- Modify: `PeerDropMac/Adapters/MacPlatformDependencies.swift`
- Modify: `PeerDropMac/App/PeerDropMacApp.swift`
- Modify: `PeerDropMac/Adapters/VoiceFeatureFlag.swift`
- Modify: `PeerDropMac/App/MacAppDelegate.swift`
- Modify: `project.yml`

- [ ] **Step 1: Final `MacPlatformDependencies.register()`**

```swift
static func register() {
    // ... existing pasteboard / deviceName / systemInfo ...
    PlatformDependencies.shared.remoteNotifications = { MacRemoteNotificationRegistering() }
    PlatformDependencies.shared.audioSession = { MacAudioSession() }
    PlatformDependencies.shared.platformIdentifier = { "macos" }
    // callProvider is wired by MacAppDelegate (not via factory — single shared instance)
}
```

- [ ] **Step 2: `MacAppDelegate` owns `MacCallProvider`**

```swift
@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    // ... existing properties ...
    let macCallProvider = MacCallProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        MacPlatformDependencies.register()
        // ... existing setup ...
    }
}
```

- [ ] **Step 3: `PeerDropMacApp.onAppear` wires CallProvider into ConnectionManager**

```swift
.onAppear {
    appDelegate.connectionManager = connectionManager
    connectionManager.configureVoiceCalling(callProvider: appDelegate.macCallProvider)
    Task {
        await PushNotificationManager.shared.requestAuthorizationAndRegister()
    }
}
```

- [ ] **Step 4: Flip the flag**

```swift
// PeerDropMac/Adapters/VoiceFeatureFlag.swift
enum MacFeatureFlags {
    static var isVoiceUIAvailable: Bool { true }
}
```

- [ ] **Step 5: Un-exclude from project.yml**

In `PeerDropMac.sources.path: PeerDrop/UI` excludes, REMOVE:
- `"Voice/**"`
- `"Settings/PushStatusRow.swift"`

Leave other Task 6b excludes intact.

- [ ] **Step 6: Build + iOS regression**

```bash
xcodegen generate
xcodebuild build -scheme PeerDropMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' 2>&1 | tail -3
xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' 2>&1 | grep "Executed " | tail -2
```

Expected: both `BUILD SUCCEEDED`; iOS 635 / 0 baseline preserved.

If `Voice/VoiceCallView.swift` has iOS-only APIs that don't compile on macOS, add inline `#if os(iOS)` gates OR add it back to excludes with a Task 12b note (Mac uses `MacVoiceCallView` regardless — VoiceCallView is iOS-rendered via the existing cross-platform reference path).

- [ ] **Step 7: Commit**

```bash
git add PeerDropMac/ project.yml PeerDrop.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
feat(m3): enable Voice UI on macOS — wire MacCallProvider end-to-end

  - MacFeatureFlags.isVoiceUIAvailable = true (M3 flip)
  - project.yml: removes Voice/** and Settings/PushStatusRow.swift
    from PeerDropMac excludes
  - MacPlatformDependencies registers remoteNotifications, audioSession,
    platformIdentifier
  - MacAppDelegate owns the MacCallProvider instance; PeerDropMacApp's
    onAppear wires connectionManager.configureVoiceCalling(callProvider:)
    + kicks PushNotificationManager.requestAuthorizationAndRegister()
  - Voice triggers in chat headers now appear on macOS — they gate on
    MacFeatureFlags.isVoiceUIAvailable which just flipped to true

iOS test sweep still 635/0.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: End-to-end smoke test + release runbook + PR

**Files:**
- Modify: `docs/release/release-runbook.md` (add M3 manual checklist)

- [ ] **Step 1: Deploy Worker**

```bash
cd cloudflare-worker
npx wrangler secret put APNS_BUNDLE_ID_MAC  # if not set in vars
npx wrangler deploy
cd ..
```

- [ ] **Step 2: Two-device manual test matrix**

Required hardware: 1 iPhone + 1 Mac (paired via SAS first).

Per spec §6 manual checklist (lines 290-301):

- [ ] iPhone → Mac call (Mac in foreground): panel appears → Accept → both sides hear audio
- [ ] iPhone → Mac call (Mac sleeping): APNs wakes app → panel appears → Accept → 10s grace window catches SDP → audio established
- [ ] iPhone → Mac call (Mac in DND): panel still appears, ringtone silent → Accept → audio works
- [ ] iPhone → Mac call (no answer 30s): panel auto-dismisses → iPhone gets "no answer"
- [ ] Mac → iPhone call: iPhone shows CallKit incoming UI → Accept → audio established
- [ ] Mac active-call window: switch Spaces via Mission Control → window stays visible
- [ ] Mac quits app mid-call: clean teardown on both sides

Capture screenshots for the runbook.

- [ ] **Step 3: Update release runbook**

Append M3 checklist + screenshots to `docs/release/release-runbook.md` under a new "M3 Voice Calling Verification" section.

- [ ] **Step 4: Tests + tag**

```bash
xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' 2>&1 | grep "Executed " | tail -2
cd PeerDropKit && swift test 2>&1 | grep "Executed " | tail -2 && cd ..

git tag -a m3-mac-voice-calling -m "M3 done: bidirectional iPhone ↔ Mac voice. NSPanel incoming + cross-Space active window + bundled ringtone + DND-aware + APNs alert push + Worker /v2/call route + cold-launch grace window. Mac App Store beta-ready."
```

- [ ] **Step 5: Push + PR**

```bash
git push -u origin <worktree-branch>:feat/m3-mac-voice-calling
gh pr create --base main --head feat/m3-mac-voice-calling --title "feat(m3): Mac voice calling — bidirectional iPhone ↔ Mac (beta)" --body "..."
```

PR body should call out:
- What ships: full bidirectional voice; Mac uses NSPanel/NSWindow + bundled ringtone + APNs alert push
- DND limitation: app-level mute detected, Focus modes not directly readable (documented)
- Cold-launch grace window: 10s buffer for SDP arrival post-APNs wake
- iOS unchanged (PushKit retained for CallKit)
- Test plan checklist (from Step 2)
- Predecessors: M0 → M2 (all merged)
- Next: M4 (submission prep)

- [ ] **Step 6: Memory update post-merge**

After PR merge, update `project-macos-port.md`:
- Mark M3 ✅ with PR # and SHA
- Add lessons learned (e.g. NSPanel vs NSWindow trade-offs, cold-launch grace window mechanism, DND fidelity compromise)

---

## Done

After M3: **beta milestone**. iPhone ↔ Mac voice calls work bidirectionally with all spec §0 demo invariants:
- Drop file → peer sheet (M2)
- iPhone-initiated call → APNs → panel (M3)
- 30s no answer → panel auto-dismiss (M3)
- After connect → call window independent, follows across Spaces (M3)
- SAS pairing (M2)
- Cross-platform chat (M2)
- Pet animation sync (M2)
- DND: ringtone silent, panel still appears (M3)

**Next:** M4 (submission prep — 4-6 days + 1-2 week Apple review buffer). Mac screenshots, metadata translation, `release_mac` lane, ASC enablement, IAP re-attach, reviewer notes.

## Lessons applied from M2

1. **Audit-driven dispatch** — Task 1 verifies plan assumptions before any implementer.
2. **Plan API names are unreliable** — audit + verify against real signatures before writing prompts.
3. **`MacFeatureFlags.isVoiceUIAvailable`** was the M2 forethought. M3 just flips the boolean.
4. **Combined spec + quality reviews** for small mechanical tasks save subagent dispatches.
5. **SourceKit "No such module" false positives** — always verify via `xcodebuild` / `swift test`.

## Open Items After M3

- M4: submission prep — Mac screenshots, metadata translation, `release_mac` lane, ASC macOS platform enablement, IAP re-attach via Playwright, reviewer notes, release-runbook updates
- Post-launch polish:
  - Focus-mode-aware DND (when Apple exposes the API)
  - Ringtone customization (user-selectable bundled options)
  - Call history / missed call notification
  - Per-window Pet sprite (decoration)
