import Foundation

/// Whether the macOS app should surface Voice UI affordances (call buttons,
/// in-call panels, etc.).
///
/// **M2: false** — Voice UI is hidden on macOS. iOS continues to expose
/// Voice via its own AppDelegate-mounted CallKitManager + VoiceCallView.
/// macOS users won't see call triggers in any reused chat / peer surface.
///
/// **M3 will flip this to true** once the custom NSWindow-based incoming-
/// call panel + APNs alert push + DND integration ship. Until then, any
/// future code that wants to add a "Call peer" button in a cross-platform
/// view should gate on `MacFeatureFlags.isVoiceUIAvailable` instead of
/// `#if os(iOS)` so M3 can unhide with a single boolean flip.
///
/// Today's M2 doesn't actually have any cross-platform-included view that
/// triggers voice — Voice/**, ContentView, ConnectionView (and the chat
/// header that exposes the phone button) are all in the project.yml
/// PeerDropMac excludes list from Task 2. The flag exists so M3 has a
/// clean toggle point.
enum MacFeatureFlags {
    static var isVoiceUIAvailable: Bool { false }
}
