import Foundation

/// Whether the macOS app should surface Voice UI affordances (call buttons,
/// in-call panels, etc.).
///
/// **M3: true** — macOS voice calling shipped. MacCallProvider is wired
/// into ConnectionManager.configureVoiceCalling(_:) at scene appearance
/// time; incoming-call NSPanel + active-call NSWindow + bundled
/// ringtone + DND-filter + APNs alert-push wake all live.
///
/// Cross-platform UI surfaces that surface a "Call peer" affordance
/// gate on this flag rather than `#if os(iOS)` so future macOS-only
/// disablement (e.g. for a regression hotfix) is a one-line edit.
enum MacFeatureFlags {
    static var isVoiceUIAvailable: Bool { true }
}
