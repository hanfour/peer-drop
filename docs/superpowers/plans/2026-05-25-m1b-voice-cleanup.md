# M1b — Voice Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove direct CallKit + AVAudioSession iOS-only dependencies from 6 files in `PeerDrop/Voice/` by introducing two new platform abstractions (`CallProvider`, `AudioSessionConfiguring`) on top of M0/M1a's `Platform/` registry. iOS behaviour preserved; macOS adapters left as no-ops for M3 (Mac voice calling) to fill in.

**Architecture:** Apply the M0/M1a Platform-registry pattern to Voice/. CallKit is iOS-only — abstract behind `CallProvider` protocol with a cross-platform `CallEndReason` enum replacing `CXCallEndedReason`. AVAudioSession is iOS-only — abstract behind `AudioSessionConfiguring` protocol with an `AudioSessionCategory` enum hiding raw `AVAudioSession.Category`/`Mode`/`CategoryOptions`. After M1b, only `CallKitManager.swift` itself imports CallKit; only the iOS audio-session adapter imports AVAudioSession's session APIs.

**Tech Stack:** Swift 5.9, iOS 16+, XCTest, XcodeGen. Builds: `xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet`. Same for `test`.

**Spec reference:** `docs/superpowers/specs/2026-05-24-macos-port-design.md` §7 M1b.

**Predecessors:**
- M0 shipped on `main` (tag `m0-core-uikit-decoupled`, merge `a3f6ba1`)
- M1a shipped on `main` (tag `m1a-pet-uikit-decoupled`, merge `32e1e3d`)

**Investigation findings:**
- `PeerDrop/Voice/` has 7 files; only `CallKitManager.swift` imports CallKit (clean boundary)
- BUT `AVAudioSession.sharedInstance()` is used in 10 sites across 6 files — AVAudioSession is iOS-only (macOS doesn't have it). Spec didn't anticipate this; M1b must abstract both
- WebRTCClient, SDPSignaling: already cross-platform (WebRTC SPM works on iOS + macOS); no abstraction needed
- VoiceCallManager line 264/269 leaks `CXCallEndedReason` via `callKitManager.reportCallEnded(reason: ...)` call sites — needs cross-platform enum substitute
- VoiceCallSession + VoiceCallManager both use `overrideOutputAudioPort(.speaker)` for speaker toggle — iOS-only; macOS doesn't need it (user picks output device via system menu)
- `requestRecordPermission`/`recordPermission` are also iOS-only (AVAudioSession). macOS uses `AVCaptureDevice.requestAccess(for: .audio)` — different API

---

## File Structure

**New files (4):**
- `PeerDrop/Core/Platform/CallProvider.swift` — protocol + `CallEndReason` enum
- `PeerDrop/Core/Platform/AudioSessionConfiguring.swift` — protocol + `AudioSessionCategory` enum
- `PeerDrop/Core/Platform/iOS/UIKitAudioSession.swift` — iOS adapter wrapping AVAudioSession
- `PeerDropTests/Core/Platform/CallProviderTests.swift` — injection test

**Modified files (10):**
- `PeerDrop/Core/Platform/PlatformDependencies.swift` — gain `callProvider` + `audioSession` factories + non-UIKit fallbacks
- `PeerDropTests/Core/Platform/MockPlatformDependencies.swift` — gain `MockCallProvider`, `MockAudioSession`, extend `mock(...)` helper
- `PeerDrop/Voice/CallKitManager.swift` — adopt `CallProvider` protocol; signature change `reportCallEnded(reason: CXCallEndedReason)` → `reportCallEnded(reason: CallEndReason)`
- `PeerDrop/Voice/VoiceCallManager.swift` — `callKitManager: CallKitManager` → `callProvider: any CallProvider`; AVAudioSession usage → `audioSession`
- `PeerDrop/Voice/VoiceCallSession.swift` — AVAudioSession usage → `audioSession`
- `PeerDrop/Voice/VoicePlayer.swift` — AVAudioSession usage → `audioSession`
- `PeerDrop/Voice/VoiceRecorder.swift` — AVAudioSession usage → `audioSession`; `requestRecordPermission` → async wrapper on protocol
- `PeerDrop/Core/ConnectionManager.swift` line 509 — `configureVoiceCalling(callKitManager: CallKitManager)` → `configureVoiceCalling(callProvider: any CallProvider)`
- `PeerDrop/App/AppDelegate.swift` — variable type stays `CallKitManager?` (iOS-side creation); passes as `CallProvider` when wiring
- `PeerDrop/App/PeerDropApp.swift` line ~101 — if `CallKitManager` type appears directly, update to read via protocol
- `.github/workflows/ci.yml` — extend `find` to also scan `PeerDrop/Voice/` (excluding the iOS-only CallKitManager.swift)

**Note on AudioSessionCategory enum:** the iOS AVAudioSession uses `(Category, Mode, [Options])` triples. We collapse the actual usage into 3 semantic cases:
- `.voiceChat` — `.playAndRecord` + `.voiceChat`
- `.playback` — `.playback` + `.default`
- `.playAndRecordSpeaker` — `.playAndRecord` + `.default` + `.defaultToSpeaker`

These 3 are the only combinations actually used in Voice/. If a 4th combination is needed later, extend the enum.

**Note on `overrideOutputAudioPort`:** iOS has explicit speaker override; macOS routes audio via system. Add `overrideOutputToSpeaker(_ speaker: Bool)` to the protocol — iOS impl forwards, macOS impl is no-op.

---

## Task 1: Create `CallEndReason` enum + `CallProvider` protocol

**Files:**
- Create: `PeerDrop/Core/Platform/CallProvider.swift`
- Test: `PeerDropTests/Core/Platform/CallProviderTests.swift`

- [ ] **Step 1: Write the failing test**

Create `PeerDropTests/Core/Platform/CallProviderTests.swift`:

```swift
import XCTest
@testable import PeerDrop

final class CallProviderTests: XCTestCase {
    func test_callEndReasonHasFourCases() {
        // Pin the cross-platform enum surface. Changes here mean CallKitManager
        // and (future M3) MacCallProvider must update their adapters.
        let allCases: [CallEndReason] = [.remoteEnded, .declinedElsewhere, .failed, .unanswered]
        XCTAssertEqual(allCases.count, 4)
    }
}
```

- [ ] **Step 2: Run, expect FAIL (type not found)**

```bash
xcodegen generate
xcodebuild test \
  -scheme PeerDrop \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -only-testing:PeerDropTests/CallProviderTests \
  -quiet 2>&1 | tail -10
```

Expected: compile error mentioning `CallEndReason` or `CallProvider` not found.

- [ ] **Step 3: Define the protocol + enum**

Create `PeerDrop/Core/Platform/CallProvider.swift`:

```swift
import Foundation

/// Cross-platform end-of-call reason. Replaces CXCallEndedReason
/// (CallKit, iOS-only) at API boundaries.
///
/// Adapter mapping:
/// - iOS CallKit: .remoteEnded → CXCallEndedReason.remoteEnded; .declinedElsewhere → .declinedElsewhere;
///   .failed → .failed; .unanswered → .unanswered
/// - macOS (M3): mapped to UI-presented strings in the in-app call panel
public enum CallEndReason {
    case remoteEnded
    case declinedElsewhere
    case failed
    case unanswered
}

/// Cross-platform call lifecycle provider. iOS implementation is
/// `CallKitManager` (wraps CXProvider + CXCallController). macOS
/// implementation (M3) draws a custom floating NSWindow panel.
///
/// Method names are deliberately CallKit-derived but the parameter
/// shapes use only Foundation + cross-platform types.
public protocol CallProvider: AnyObject {
    /// Called by the provider when the user answers the incoming-call UI.
    /// Set by the consumer (VoiceCallManager) at wire-up time.
    var onAnswerCall: (() -> Void)? { get set }

    /// Called by the provider when the user ends an active call.
    /// Set by the consumer (VoiceCallManager) at wire-up time.
    var onEndCall: (() -> Void)? { get set }

    /// Start an outgoing call with the given peer's display name.
    func startOutgoingCall(to peerName: String)

    /// Report that the outgoing call has connected (remote answered).
    func reportOutgoingCallConnected()

    /// Report an incoming call. Async because iOS CallKit's reportNewIncomingCall
    /// is async/throws. macOS impl just shows the panel and resolves.
    func reportIncomingCall(from peerName: String) async throws

    /// End the current call (user-initiated from UI).
    func endCall()

    /// Report that the call ended for the given reason.
    func reportCallEnded(reason: CallEndReason)

    /// Configure platform audio session for active voice call (iOS only;
    /// macOS no-op since the system handles voice-chat routing).
    func configureAudioSession()
}
```

- [ ] **Step 4: Re-run test, expect PASS**

```bash
xcodebuild test \
  -scheme PeerDrop \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -only-testing:PeerDropTests/CallProviderTests \
  -quiet
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add PeerDrop/Core/Platform/CallProvider.swift PeerDropTests/Core/Platform/CallProviderTests.swift PeerDrop.xcodeproj
git commit -m "$(cat <<'EOF'
refactor(core): add CallProvider protocol + CallEndReason enum (M1b)

Cross-platform call lifecycle abstraction. iOS adapter (CallKitManager
conformance) lands in M1b Task 3. macOS adapter deferred to M3.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Create `AudioSessionCategory` enum + `AudioSessionConfiguring` protocol

**Files:**
- Create: `PeerDrop/Core/Platform/AudioSessionConfiguring.swift`

- [ ] **Step 1: Define protocol + enum**

Create `PeerDrop/Core/Platform/AudioSessionConfiguring.swift`:

```swift
import Foundation

/// Cross-platform audio session category. iOS maps each case to a
/// (AVAudioSession.Category, Mode, [CategoryOptions]) triple; macOS
/// has no session category concept so each case is effectively a no-op
/// (system routes audio automatically).
///
/// Only the 3 combinations actually used in PeerDrop/Voice/ are
/// exposed. Add a 4th case if a new combination is needed.
public enum AudioSessionCategory {
    /// AVAudioSession: .playAndRecord + .voiceChat
    /// Used by CallKitManager + during active voice call.
    case voiceChat

    /// AVAudioSession: .playback + .default
    /// Used by VoicePlayer (ringtone playback, voice-note playback).
    case playback

    /// AVAudioSession: .playAndRecord + .default + .defaultToSpeaker
    /// Used by VoiceRecorder (voice-note capture with speaker monitor).
    case playAndRecordSpeaker
}

/// Cross-platform audio session abstraction. iOS implementation wraps
/// AVAudioSession.sharedInstance(). macOS no-op (the system handles
/// voice-chat audio routing automatically).
public protocol AudioSessionConfiguring: AnyObject {
    /// Configure the session for the given semantic category and activate it.
    /// iOS: calls setCategory + setActive(true). macOS: no-op.
    /// Throws on iOS if the category is incompatible with the current device state.
    func activate(_ category: AudioSessionCategory) throws

    /// Deactivate the session. iOS: calls setActive(false, options: .notifyOthersOnDeactivation).
    /// macOS: no-op.
    func deactivate() throws

    /// Override output to speaker (iOS only; macOS no-op since user picks
    /// output device via system menu).
    func overrideOutputToSpeaker(_ speaker: Bool) throws

    /// Synchronous read of current microphone permission status.
    /// iOS: AVAudioSession.recordPermission == .granted.
    /// macOS: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized.
    var recordPermissionGranted: Bool { get }

    /// Async request for microphone permission.
    /// iOS: wraps AVAudioSession.requestRecordPermission.
    /// macOS: wraps AVCaptureDevice.requestAccess(for: .audio).
    func requestRecordPermission() async -> Bool
}
```

- [ ] **Step 2: Build (no test yet — tested indirectly via VoiceRecorder/VoicePlayer refactors)**

```bash
xcodegen generate
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add PeerDrop/Core/Platform/AudioSessionConfiguring.swift PeerDrop.xcodeproj
git commit -m "$(cat <<'EOF'
refactor(core): add AudioSessionConfiguring protocol (M1b)

Cross-platform audio session abstraction. iOS wraps AVAudioSession;
macOS no-op since the system handles voice-chat routing.
AudioSessionCategory enum collapses the 3 (category, mode, options)
combinations actually used in PeerDrop/Voice/.

iOS adapter lands in M1b Task 4.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: CallKitManager adopts CallProvider protocol

**Files:**
- Modify: `PeerDrop/Voice/CallKitManager.swift`

The existing `CallKitManager` already has the 6 methods the protocol requires (with slight signature differences — `reportCallEnded(reason: CXCallEndedReason)` becomes `reportCallEnded(reason: CallEndReason)`). Need to:
1. Add `: CallProvider` to the class declaration
2. Change the `reportCallEnded` signature + add internal mapping from `CallEndReason` to `CXCallEndedReason`

- [ ] **Step 1: Read current CallKitManager**

```bash
sed -n '1,50p' PeerDrop/Voice/CallKitManager.swift
sed -n '115,135p' PeerDrop/Voice/CallKitManager.swift
```

Note the current class declaration and the `reportCallEnded(reason:)` signature.

- [ ] **Step 2: Add protocol conformance**

Find the class declaration (likely `class CallKitManager: NSObject, CXProviderDelegate` or similar). Add `, CallProvider`:

```swift
class CallKitManager: NSObject, CXProviderDelegate, CallProvider {
```

- [ ] **Step 3: Change `reportCallEnded` signature**

Find the method (around line 119):

```swift
// Before:
func reportCallEnded(reason: CXCallEndedReason = .remoteEnded) {
    guard let uuid = activeCallUUID else { return }
    logger.info("Reporting call ended: \(reason.rawValue)")
    provider?.reportCall(with: uuid, endedAt: nil, reason: reason)
    activeCallUUID = nil
}

// After:
func reportCallEnded(reason: CallEndReason) {
    guard let uuid = activeCallUUID else { return }
    let cxReason = Self.mapToCXReason(reason)
    logger.info("Reporting call ended: \(cxReason.rawValue)")
    provider?.reportCall(with: uuid, endedAt: nil, reason: cxReason)
    activeCallUUID = nil
}

private static func mapToCXReason(_ reason: CallEndReason) -> CXCallEndedReason {
    switch reason {
    case .remoteEnded:        return .remoteEnded
    case .declinedElsewhere:  return .declinedElsewhere
    case .failed:             return .failed
    case .unanswered:         return .unanswered
    }
}
```

Note: the protocol method has NO default value; the spec method had `reason: CXCallEndedReason = .remoteEnded`. Removing the default forces every call site to pass an explicit reason — which is fine because the 2 call sites in VoiceCallManager (lines 264, 269) already pass explicit values.

- [ ] **Step 4: Build to find call-site breaks**

```bash
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet 2>&1 | tail -20
```

Expected: build errors at VoiceCallManager.swift lines 264 + 269 because they pass `CXCallEndedReason` literals (e.g., `.declinedElsewhere`, `.remoteEnded`) which now need to be the `CallEndReason` enum literals.

The fix: at the call sites in VoiceCallManager.swift, change:
- `callKitManager.reportCallEnded(reason: .declinedElsewhere)` → still compiles because Swift can infer `.declinedElsewhere` as `CallEndReason.declinedElsewhere` from the param type
- `callKitManager.reportCallEnded(reason: .remoteEnded)` → same

Actually these call sites should just work without modification because Swift's type inference resolves `.declinedElsewhere` against the new `CallEndReason` parameter type. Verify by building.

If anywhere passes `CXCallEndedReason.X` explicitly (with the type prefix), that needs updating. Search:

```bash
grep -n "CXCallEndedReason\." PeerDrop/Voice/ PeerDrop/Core/ PeerDrop/App/ 2>/dev/null
```

- [ ] **Step 5: Re-build, expect SUCCESS**

```bash
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add PeerDrop/Voice/CallKitManager.swift
git commit -m "$(cat <<'EOF'
refactor(voice): CallKitManager adopts CallProvider protocol (M1b)

- Conforms to CallProvider
- reportCallEnded signature: CXCallEndedReason → CallEndReason
- Private mapToCXReason maps the cross-platform enum to CallKit
- VoiceCallManager call sites unchanged (Swift type inference)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Create iOS adapter `UIKitAudioSession`

**Files:**
- Create: `PeerDrop/Core/Platform/iOS/UIKitAudioSession.swift`

- [ ] **Step 1: Create iOS adapter**

Create `PeerDrop/Core/Platform/iOS/UIKitAudioSession.swift`:

```swift
#if canImport(UIKit)
import Foundation
import AVFoundation

final class UIKitAudioSession: AudioSessionConfiguring {
    private let session = AVAudioSession.sharedInstance()

    func activate(_ category: AudioSessionCategory) throws {
        switch category {
        case .voiceChat:
            try session.setCategory(.playAndRecord, mode: .voiceChat)
        case .playback:
            try session.setCategory(.playback, mode: .default)
        case .playAndRecordSpeaker:
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        }
        try session.setActive(true)
    }

    func deactivate() throws {
        try session.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    func overrideOutputToSpeaker(_ speaker: Bool) throws {
        try session.overrideOutputAudioPort(speaker ? .speaker : .none)
    }

    var recordPermissionGranted: Bool {
        session.recordPermission == .granted
    }

    func requestRecordPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            session.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
#endif
```

- [ ] **Step 2: Build**

```bash
xcodegen generate
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add PeerDrop/Core/Platform/iOS/UIKitAudioSession.swift PeerDrop.xcodeproj
git commit -m "$(cat <<'EOF'
refactor(core): add UIKitAudioSession iOS adapter (M1b)

Wraps AVAudioSession.sharedInstance() behind AudioSessionConfiguring
protocol. Covers all 3 category combinations actually used in
PeerDrop/Voice/ plus speaker-override + mic-permission.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Extend PlatformDependencies with `callProvider` + `audioSession` factories

**Files:**
- Modify: `PeerDrop/Core/Platform/PlatformDependencies.swift`

Follow the existing nil-defaulted + cached static pattern (extending the 5 factories from M0/M1a to 7 total).

- [ ] **Step 1: Read current PlatformDependencies.swift**

```bash
cat PeerDrop/Core/Platform/PlatformDependencies.swift
```

Note the existing 5 factories and the `#if !canImport(UIKit)` no-op block.

- [ ] **Step 2: Apply the extension**

Add to `PeerDrop/Core/Platform/PlatformDependencies.swift`:

1. Two new `public var` properties after the existing 5:
   ```swift
   public var callProvider: () -> CallProvider
   public var audioSession: () -> AudioSessionConfiguring
   ```
2. Two new init params (nil-defaulted, with nil-coalesce to `Self.makeX()`):
   ```swift
   callProvider: (() -> CallProvider)? = nil,
   audioSession: (() -> AudioSessionConfiguring)? = nil
   ```
   And inside `init`:
   ```swift
   self.callProvider = callProvider ?? { PlatformDependencies.makeCallProvider() }
   self.audioSession = audioSession ?? { PlatformDependencies.makeAudioSession() }
   ```
3. Two new cached static lets:
   ```swift
   /// IMPORTANT: callProvider default is NoOpCallProvider on BOTH platforms.
   /// On iOS, AppDelegate is the sole creator of the real CallKitManager
   /// (because CallKit needs a CXProvider delegate wired to the app's UI).
   /// AppDelegate must pass the instance via ConnectionManager.configureVoiceCalling(callProvider:).
   /// If callProvider() is read before AppDelegate runs, the NoOp prevents
   /// silent double-instantiation of CXProvider. macOS (M3) likewise creates
   /// the real implementation in its NSApplicationDelegate.
   private static let _defaultCallProvider: CallProvider = AlwaysNoOpCallProvider()
   private static func makeCallProvider() -> CallProvider { _defaultCallProvider }

   private static let _defaultAudioSession: AudioSessionConfiguring = {
       #if canImport(UIKit)
       return UIKitAudioSession()
       #else
       return NoOpAudioSession()
       #endif
   }()
   private static func makeAudioSession() -> AudioSessionConfiguring { _defaultAudioSession }
   ```

   Note: AudioSession DOES use the per-platform default (iOS gets the real UIKitAudioSession) because there's no equivalent ownership concern — AVAudioSession.sharedInstance() is a process-wide singleton, so multiple wrapper instances are safe.

4. The `AlwaysNoOpCallProvider` is unconditional (defined OUTSIDE the `#if !canImport(UIKit)` block). Plus a `NoOpAudioSession` inside the `#if !canImport(UIKit)` block:
   ```swift
   // AlwaysNoOpCallProvider lives OUTSIDE the #if block — used on iOS too,
   // because AppDelegate is the sole creator of the real CallKitManager.
   // The default exists only so reading PlatformDependencies.shared.callProvider()
   // before AppDelegate runs (e.g. in tests) doesn't crash.
   private final class AlwaysNoOpCallProvider: CallProvider {
       var onAnswerCall: (() -> Void)?
       var onEndCall: (() -> Void)?
       func startOutgoingCall(to peerName: String) {}
       func reportOutgoingCallConnected() {}
       func reportIncomingCall(from peerName: String) async throws {}
       func endCall() {}
       func reportCallEnded(reason: CallEndReason) {}
       func configureAudioSession() {}
   }

   #if !canImport(UIKit)
   private final class NoOpAudioSession: AudioSessionConfiguring {
       func activate(_ category: AudioSessionCategory) throws {}
       func deactivate() throws {}
       func overrideOutputToSpeaker(_ speaker: Bool) throws {}
       var recordPermissionGranted: Bool { false }
       func requestRecordPermission() async -> Bool { false }
   }
   #endif
   ```

The `AlwaysNoOpCallProvider` does NOT reference `CallKitManager` — that's an intentional design choice to avoid double-instantiation (see the IMPORTANT comment in Step 2 above). The iOS app launches CallKitManager via AppDelegate, then calls `connectionManager.configureVoiceCalling(callProvider: callKitManager!)` which routes the real instance into VoiceCallManager.

- [ ] **Step 3: Build**

```bash
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet
```

Expected: `** BUILD SUCCEEDED **`.

If there's a CallKitManager-not-found error in the iOS-default branch, you may need to add `import` or just verify CallKitManager isn't marked `private`/`fileprivate`. Adjust accordingly.

- [ ] **Step 4: Commit**

```bash
git add PeerDrop/Core/Platform/PlatformDependencies.swift
git commit -m "$(cat <<'EOF'
refactor(core): PlatformDependencies gains callProvider + audioSession (M1b)

7 total factories (pasteboard, haptics, deviceName, systemInfo,
remoteNotifications, callProvider, audioSession). Cached static
default pattern unchanged. macOS no-op fallbacks added.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Extend MockPlatformDependencies with `MockCallProvider` + `MockAudioSession`

**Files:**
- Modify: `PeerDropTests/Core/Platform/MockPlatformDependencies.swift`

- [ ] **Step 1: Append mocks**

Append to `PeerDropTests/Core/Platform/MockPlatformDependencies.swift` (after the existing mocks):

```swift
final class MockCallProvider: CallProvider {
    var onAnswerCall: (() -> Void)?
    var onEndCall: (() -> Void)?
    private(set) var invocations: [String] = []
    var configureAudioSessionThrows: Error?

    func startOutgoingCall(to peerName: String) {
        invocations.append("startOutgoingCall:\(peerName)")
    }
    func reportOutgoingCallConnected() {
        invocations.append("reportOutgoingCallConnected")
    }
    func reportIncomingCall(from peerName: String) async throws {
        invocations.append("reportIncomingCall:\(peerName)")
    }
    func endCall() {
        invocations.append("endCall")
    }
    func reportCallEnded(reason: CallEndReason) {
        invocations.append("reportCallEnded:\(reason)")
    }
    func configureAudioSession() {
        invocations.append("configureAudioSession")
    }
}

final class MockAudioSession: AudioSessionConfiguring {
    private(set) var invocations: [String] = []
    var mockRecordPermissionGranted: Bool = true
    var mockRequestRecordPermissionResult: Bool = true

    func activate(_ category: AudioSessionCategory) throws {
        invocations.append("activate:\(category)")
    }
    func deactivate() throws {
        invocations.append("deactivate")
    }
    func overrideOutputToSpeaker(_ speaker: Bool) throws {
        invocations.append("overrideOutputToSpeaker:\(speaker)")
    }
    var recordPermissionGranted: Bool { mockRecordPermissionGranted }
    func requestRecordPermission() async -> Bool { mockRequestRecordPermissionResult }
}
```

- [ ] **Step 2: Extend `mock(...)` helper**

Find the existing `extension PlatformDependencies { static func mock(...) }` helper and extend with `callProvider:` + `audioSession:`:

```swift
extension PlatformDependencies {
    static func mock(
        pasteboard: MockPasteboard = MockPasteboard(),
        haptics: MockHaptics = MockHaptics(),
        deviceName: MockDeviceNameProvider = MockDeviceNameProvider(),
        systemInfo: MockSystemInfoProvider = MockSystemInfoProvider(),
        remoteNotifications: MockRemoteNotificationRegistering = MockRemoteNotificationRegistering(),
        callProvider: MockCallProvider = MockCallProvider(),
        audioSession: MockAudioSession = MockAudioSession()
    ) -> PlatformDependencies {
        PlatformDependencies(
            pasteboard: { pasteboard },
            haptics: { haptics },
            deviceName: { deviceName },
            systemInfo: { systemInfo },
            remoteNotifications: { remoteNotifications },
            callProvider: { callProvider },
            audioSession: { audioSession }
        )
    }
}
```

(Read the current helper signature first to confirm the exact form.)

- [ ] **Step 3: Add a sanity test**

Append to the same file (inside `CallProviderTests` or a new class):

```swift
final class CallProviderInjectionTests: XCTestCase {
    func test_mockCallProvider_recordsInvocations() {
        let mock = MockCallProvider()
        mock.startOutgoingCall(to: "Alice")
        mock.reportOutgoingCallConnected()
        mock.endCall()
        mock.reportCallEnded(reason: .remoteEnded)

        XCTAssertEqual(mock.invocations, [
            "startOutgoingCall:Alice",
            "reportOutgoingCallConnected",
            "endCall",
            "reportCallEnded:remoteEnded",
        ])
    }
}
```

- [ ] **Step 4: Build + test**

```bash
xcodebuild test \
  -scheme PeerDrop \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -only-testing:PeerDropTests/CallProviderInjectionTests \
  -only-testing:PeerDropTests/CallProviderTests \
  -quiet
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add PeerDropTests/Core/Platform/MockPlatformDependencies.swift
git commit -m "$(cat <<'EOF'
refactor(core): add MockCallProvider + MockAudioSession (M1b)

Both record invocations like MockHaptics. mock(...) helper extended
to 7 factory params. New CallProviderInjectionTests pins the mock
contract.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Refactor VoiceRecorder (audioSession via injection)

**Files:**
- Modify: `PeerDrop/Voice/VoiceRecorder.swift`

VoiceRecorder uses AVAudioSession at lines 21, 106, 114:
- Line 21: `try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker]); try session.setActive(true)` — becomes `try audioSession.activate(.playAndRecordSpeaker)`
- Line 106: `AVAudioSession.sharedInstance().requestRecordPermission { granted in ... }` — becomes `await audioSession.requestRecordPermission()`
- Line 114: `AVAudioSession.sharedInstance().recordPermission == .granted` — becomes `audioSession.recordPermissionGranted`

- [ ] **Step 1: Read current VoiceRecorder**

```bash
cat PeerDrop/Voice/VoiceRecorder.swift
```

Note the class structure, init, and the 3 AVAudioSession call sites.

- [ ] **Step 2: Add `audioSession` injection in init**

Edit the class:
- Add `private let audioSession: AudioSessionConfiguring` property
- Change init to accept `audioSession: AudioSessionConfiguring = PlatformDependencies.shared.audioSession()`
- Store the injected value

- [ ] **Step 3: Replace the 3 AVAudioSession call sites**

For each of the 3 lines (21, 106, 114), replace the AVAudioSession call with the abstracted call as listed above.

The `requestRecordPermission` site (line 106) was inside a callback-based `withCheckedContinuation`. The protocol's async API simplifies this — the call site can now be:

```swift
// Before:
return await withCheckedContinuation { continuation in
    AVAudioSession.sharedInstance().requestRecordPermission { granted in
        continuation.resume(returning: granted)
    }
}

// After:
return await audioSession.requestRecordPermission()
```

- [ ] **Step 4: Drop `import AVFoundation` if no longer needed**

```bash
grep -nE "AVAudioRecorder|AVAudioPlayer|AVAudioFile|AVFormat|AVAudioCommon" PeerDrop/Voice/VoiceRecorder.swift
```

VoiceRecorder almost certainly still uses `AVAudioRecorder` for the actual recording — keep `import AVFoundation`. Don't drop it.

- [ ] **Step 5: Build**

```bash
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add PeerDrop/Voice/VoiceRecorder.swift
git commit -m "$(cat <<'EOF'
refactor(voice): VoiceRecorder uses AudioSessionConfiguring (M1b)

3 AVAudioSession.sharedInstance() sites replaced with injected
audioSession. requestRecordPermission async wrapper simplifies the
callback-based permission flow. import AVFoundation retained for
AVAudioRecorder usage.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Refactor VoicePlayer (audioSession via injection)

**Files:**
- Modify: `PeerDrop/Voice/VoicePlayer.swift`

VoicePlayer uses AVAudioSession at lines 25, 50 — both `setCategory(.playback, mode: .default); setActive(true)`. Replace with `try audioSession.activate(.playback)`.

- [ ] **Step 1: Read current VoicePlayer**

```bash
cat PeerDrop/Voice/VoicePlayer.swift
```

- [ ] **Step 2: Add `audioSession` injection in init**

Same pattern as VoiceRecorder. Add `private let audioSession: AudioSessionConfiguring`; init param with default `PlatformDependencies.shared.audioSession()`.

- [ ] **Step 3: Replace the 2 AVAudioSession blocks**

Both sites:

```swift
// Before:
let session = AVAudioSession.sharedInstance()
try session.setCategory(.playback, mode: .default)
try session.setActive(true)

// After:
try audioSession.activate(.playback)
```

- [ ] **Step 4: Build**

```bash
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add PeerDrop/Voice/VoicePlayer.swift
git commit -m "$(cat <<'EOF'
refactor(voice): VoicePlayer uses AudioSessionConfiguring (M1b)

2 AVAudioSession.sharedInstance() sites replaced with
audioSession.activate(.playback). import AVFoundation retained for
AVAudioPlayer usage.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Refactor VoiceCallSession (audioSession + speaker toggle)

**Files:**
- Modify: `PeerDrop/Voice/VoiceCallSession.swift`

VoiceCallSession uses AVAudioSession at line 127 — `setCategory + setActive + overrideOutputAudioPort` for speaker toggle.

- [ ] **Step 1: Read VoiceCallSession around line 120-140**

```bash
sed -n '115,145p' PeerDrop/Voice/VoiceCallSession.swift
```

Identify the exact block.

- [ ] **Step 2: Add `audioSession` injection + replace the block**

Add the property + init param as in Tasks 7 + 8. Then replace the AVAudioSession block with two calls:

```swift
// Before (approximate):
let session = AVAudioSession.sharedInstance()
do {
    if isSpeakerOn {
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
        try session.overrideOutputAudioPort(.speaker)
    } else {
        try session.setCategory(.playAndRecord, mode: .voiceChat)
        try session.overrideOutputAudioPort(.none)
    }
} catch { ... }

// After:
do {
    try audioSession.activate(.voiceChat)
    try audioSession.overrideOutputToSpeaker(isSpeakerOn)
} catch { ... }
```

(Read the actual code to make sure the speaker toggle logic is preserved — the above is a simplification; adapt to actual variable names.)

- [ ] **Step 3: Build**

```bash
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add PeerDrop/Voice/VoiceCallSession.swift
git commit -m "$(cat <<'EOF'
refactor(voice): VoiceCallSession uses AudioSessionConfiguring (M1b)

AVAudioSession setCategory + setActive + overrideOutputAudioPort
collapsed into audioSession.activate(.voiceChat) +
audioSession.overrideOutputToSpeaker(...). Speaker toggle behavior
preserved.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Refactor VoiceCallManager (callProvider + audioSession)

**Files:**
- Modify: `PeerDrop/Voice/VoiceCallManager.swift`

This is the biggest single-file change in M1b. VoiceCallManager has:
- 9 references to `callKitManager.X` (type currently `CallKitManager`)
- 1 AVAudioSession usage at line 375
- init signature `init(connectionManager: ConnectionManager, callKitManager: CallKitManager)`

- [ ] **Step 1: Read VoiceCallManager structure**

```bash
sed -n '80,110p' PeerDrop/Voice/VoiceCallManager.swift
sed -n '370,390p' PeerDrop/Voice/VoiceCallManager.swift
```

- [ ] **Step 2: Change the property + init type**

```swift
// Before:
private let callKitManager: CallKitManager
...
init(connectionManager: ConnectionManager, callKitManager: CallKitManager) {
    ...
    self.callKitManager = callKitManager
    ...
}

// After:
private let callProvider: any CallProvider
private let audioSession: AudioSessionConfiguring
...
init(connectionManager: ConnectionManager,
     callProvider: any CallProvider,
     audioSession: AudioSessionConfiguring = PlatformDependencies.shared.audioSession()) {
    ...
    self.callProvider = callProvider
    self.audioSession = audioSession
    ...
}
```

- [ ] **Step 3: Update the 9 call-site references**

Find each `callKitManager.X` and replace with `callProvider.X`. The 9 sites are at lines 99, 105, 152, 175, 197, 244, 264, 269, 353 (per the earlier grep). Swift's type inference handles the `.declinedElsewhere` / `.remoteEnded` literals because `CallEndReason` has matching cases.

```bash
grep -n "callKitManager\." PeerDrop/Voice/VoiceCallManager.swift
```

For each match, use Edit to replace `callKitManager` with `callProvider`.

- [ ] **Step 4: Replace the AVAudioSession site at line ~375**

```bash
sed -n '370,385p' PeerDrop/Voice/VoiceCallManager.swift
```

Replace the block with `try audioSession.overrideOutputToSpeaker(isSpeakerOn)` (or appropriate based on actual code).

- [ ] **Step 5: Build**

```bash
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`. If errors mention `CallKitManager` type usage elsewhere (ConnectionManager, AppDelegate, PeerDropApp), that's Task 11 — DO NOT fix those here.

- [ ] **Step 6: Commit**

```bash
git add PeerDrop/Voice/VoiceCallManager.swift
git commit -m "$(cat <<'EOF'
refactor(voice): VoiceCallManager uses CallProvider + AudioSession (M1b)

- callKitManager: CallKitManager → callProvider: any CallProvider
- audioSession injected via PlatformDependencies default
- 9 callKitManager.X sites updated to callProvider.X
- 1 AVAudioSession.sharedInstance() site → audioSession.overrideOutputToSpeaker

The cross-file wiring (ConnectionManager.configureVoiceCalling
signature, AppDelegate, PeerDropApp) is updated in Task 11.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

NOTE: After this commit, the build will be BROKEN until Task 11 fixes ConnectionManager + AppDelegate + PeerDropApp. Don't run the full test suite between Tasks 10 and 11. This is the only intentionally-broken intermediate state in M1b.

---

## Task 11: Update ConnectionManager + AppDelegate + PeerDropApp wiring

**Files:**
- Modify: `PeerDrop/Core/ConnectionManager.swift` line 509-512
- Modify: `PeerDrop/App/AppDelegate.swift`
- Modify: `PeerDrop/App/PeerDropApp.swift` line ~101

- [ ] **Step 1: Update ConnectionManager.configureVoiceCalling signature**

Edit `PeerDrop/Core/ConnectionManager.swift` around line 509-512:

```swift
// Before:
func configureVoiceCalling(callKitManager: CallKitManager) {
    self.voiceCallManager = VoiceCallManager(connectionManager: self, callKitManager: callKitManager)
}

// After:
func configureVoiceCalling(callProvider: any CallProvider) {
    self.voiceCallManager = VoiceCallManager(connectionManager: self, callProvider: callProvider)
}
```

- [ ] **Step 2: Update AppDelegate**

Read current AppDelegate.swift:

```bash
cat PeerDrop/App/AppDelegate.swift
```

The variable `var callKitManager: CallKitManager?` stays — AppDelegate is the iOS-specific creation point. But the caller that passes it to ConnectionManager.configureVoiceCalling needs to pass it as a `CallProvider`:

```swift
// Before (somewhere in AppDelegate or wherever configureVoiceCalling is called):
connectionManager.configureVoiceCalling(callKitManager: callKitManager!)

// After:
connectionManager.configureVoiceCalling(callProvider: callKitManager!)
```

(Type inference handles the protocol conformance because `CallKitManager: CallProvider`.)

If the parameter name is positional, you may not need to change the call site at all. Check by grepping:

```bash
grep -rn "configureVoiceCalling" PeerDrop/ PeerDropTests/ 2>/dev/null
```

Update each call site to use the new parameter label (`callProvider:` not `callKitManager:`).

- [ ] **Step 3: Update PeerDropApp.swift line ~101**

```bash
sed -n '95,110p' PeerDrop/App/PeerDropApp.swift
```

If the line is `connectionManager.configureVoiceCalling(callKitManager: appDelegate.callKitManager)`, change to `connectionManager.configureVoiceCalling(callProvider: appDelegate.callKitManager!)` (note: pass the `CallKitManager?` unwrapped, since the protocol is non-optional).

If the line just imports CallKit or references CallKitManager incidentally, leave alone.

- [ ] **Step 4: Build + run full test suite**

```bash
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet
xcodebuild test \
  -scheme PeerDrop \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  2>&1 | tee /tmp/m1b-task11-tests.log | tail -10
```

Expected: build succeeds + same 12 pre-existing failures as M0/M1a baseline (no new regressions).

Confirm by extracting failures:
```bash
grep -E "Test Case '-\[.*\]' failed" /tmp/m1b-task11-tests.log | sort -u
```

Compare to the M0 baseline list (DoubleRatchetTests ×7, DoubleRatchetPersistenceTests ×2, MainBundleAssetCoverageTests ×1, PetGenomeSpeciesTests ×1, VariantTraitsTests ×1).

- [ ] **Step 5: Commit**

```bash
git add PeerDrop/Core/ConnectionManager.swift PeerDrop/App/AppDelegate.swift PeerDrop/App/PeerDropApp.swift
git commit -m "$(cat <<'EOF'
refactor(app): wire CallProvider through ConnectionManager + AppDelegate (M1b)

- ConnectionManager.configureVoiceCalling(callKitManager:) signature
  changed to (callProvider: any CallProvider)
- AppDelegate + PeerDropApp call sites updated to use new label
- AppDelegate still creates CallKitManager directly (iOS-specific);
  it's the only file that imports CallKit besides CallKitManager.swift

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: Verify Voice/ is iOS-only-clean + extend lint-imports CI + tag

**Files:**
- Verify only; possibly Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: Scan for CallKit imports outside CallKitManager.swift**

```bash
grep -rn "^import CallKit\|^import CXProvider" PeerDrop/ | grep -v "PeerDrop/Voice/CallKitManager.swift" | grep -v "PeerDrop/App/AppDelegate.swift"
```

Expected: empty. Only CallKitManager.swift + AppDelegate.swift may import CallKit. If any other file appears, M1b missed a refactor — fix that file.

- [ ] **Step 2: Scan for AVAudioSession usage outside the iOS adapter**

```bash
grep -rn "AVAudioSession" PeerDrop/Core/ PeerDrop/Voice/ | grep -v "PeerDrop/Core/Platform/iOS/UIKitAudioSession.swift"
```

Expected: empty. Only `UIKitAudioSession.swift` should use AVAudioSession directly. If any matches appear in Voice/, that file was missed.

- [ ] **Step 3: Extend lint-imports CI to scan Voice/ (except CallKitManager)**

Edit `.github/workflows/ci.yml`. Find the find command (currently scans Core + Pet) and extend to Voice/:

```yaml
done < <(find PeerDrop/Core PeerDrop/Pet PeerDrop/Voice -name "*.swift" \
  -not -path "*/Platform/iOS/*" \
  -not -path "*/Pet/UI/*" \
  -not -path "*/Voice/CallKitManager.swift")
```

The `-not -path "*/Voice/CallKitManager.swift"` exempts the one file that legitimately imports CallKit. AVAudioSession isn't caught by the lint (it only catches UIKit/AppKit/WidgetKit imports), but the spec-compliance reviewer will check the AVAudioSession grep manually.

- [ ] **Step 4: Run the lint script locally to confirm "Clean."**

```bash
cd "/Volumes/SATECHI DISK Media/UserFolders/Projects/applications/peer-drop"

violations=""
while IFS= read -r file; do
  if grep -E "^import (UIKit|AppKit|WidgetKit)" "$file" > /dev/null 2>&1; then
    while IFS= read -r line_no; do
      prev_line=$((line_no - 1))
      prev=$(sed -n "${prev_line}p" "$file" | tr -d '[:space:]')
      if [ "$prev" != "#ifos(iOS)" ] && \
         [ "$prev" != "#ifcanImport(UIKit)" ] && \
         [ "$prev" != "#ifcanImport(AppKit)" ] && \
         [ "$prev" != "#ifcanImport(WidgetKit)" ] && \
         [ "$prev" != "#elseifcanImport(UIKit)" ] && \
         [ "$prev" != "#elseifcanImport(AppKit)" ] && \
         [ "$prev" != "#elseifcanImport(WidgetKit)" ] && \
         [ "$prev" != "#elseifos(iOS)" ]; then
        violations+="$file:$line_no\n"
      fi
    done < <(grep -n -E "^import (UIKit|AppKit|WidgetKit)" "$file" | cut -d: -f1)
  fi
done < <(find PeerDrop/Core PeerDrop/Pet PeerDrop/Voice -name "*.swift" \
  -not -path "*/Platform/iOS/*" \
  -not -path "*/Pet/UI/*" \
  -not -path "*/Voice/CallKitManager.swift")
if [ -n "$violations" ]; then
  printf "Violations:\n%b" "$violations"
else
  echo "Clean."
fi
```

Expected: `Clean.`

- [ ] **Step 5: Run full test suite + verify zero new regressions**

```bash
xcodebuild test \
  -scheme PeerDrop \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  2>&1 | tee /tmp/m1b-final-tests.log | tail -10
```

Expected: same 12 pre-existing failures as M0/M1a baseline. Extract:

```bash
grep -E "Test Case '-\[.*\]' failed" /tmp/m1b-final-tests.log | sort -u
```

If any NEW failure appears, investigate before tagging.

- [ ] **Step 6: Commit CI update + tag**

```bash
git add .github/workflows/ci.yml
git commit -m "$(cat <<'EOF'
ci: extend lint-imports to scan PeerDrop/Voice/ (M1b)

After M1b's Voice cleanup, only Voice/CallKitManager.swift (iOS-only
adapter) legitimately imports CallKit. lint-imports now enforces no
unguarded UIKit/AppKit/WidgetKit in Voice/ as well.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"

git tag -a m1b-voice-cleanup -m "M1b done: Voice/ CallKit + AVAudioSession isolated behind CallProvider + AudioSessionConfiguring"
```

---

## Done

M1b complete. `PeerDrop/Voice/` is iOS-CallKit-clean (only CallKitManager.swift + AppDelegate.swift import CallKit) and iOS-AVAudioSession-clean (only UIKitAudioSession.swift uses AVAudioSession directly). PlatformDependencies registry now has 7 abstractions:

| # | Protocol | Added in |
|---|---|---|
| 1 | PlatformPasteboard | M0 |
| 2 | HapticFeedback | M0 + M1a (`evolutionTriggered`) |
| 3 | DeviceNameProvider | M0 |
| 4 | SystemInfoProvider | M0 |
| 5 | RemoteNotificationRegistering | M0 |
| 6 | CallProvider | M1b |
| 7 | AudioSessionConfiguring | M1b |

Plus typealiases (`PlatformImage`, `PlatformColor`) + helpers (`PlatformGraphicsRenderer`).

**Next:** M1c plan (SPM scaffold + empty modules) by re-invoking `superpowers:writing-plans`.

## Open Items for M1c / M1d / M2+

1. **M1c:** Create `PeerDropKit/Package.swift` with 5 product modules + dependency graph; modules stay empty (compile only)
2. **M1d:** Move ~90 files into modules; update `project.yml` so app target + widget consume PeerDropKit; move Pet/ resources into SPM bundle
3. **M3:** Implement MacCallProvider (custom NSWindow incoming-call panel) + audio routing via system (no AVAudioSession needed)
4. **Pre-M1c ship gate:** triage 12 pre-existing DoubleRatchetTests failures on `main` (carried since M0 baseline)
