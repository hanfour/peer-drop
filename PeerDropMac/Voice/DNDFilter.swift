#if canImport(AppKit)
import UserNotifications
import os

/// Decides whether the incoming-call ringtone should be muted while
/// still letting the panel appear.
///
/// **Spec §0 line 9 / §2 line 87:** DND-aware. Panel always shows;
/// audio is what gets silenced.
///
/// **Detection strategy:** read `UNUserNotificationCenter.notificationSettings()`
/// — if `soundSetting == .disabled` or `notificationCenterSetting == .disabled`,
/// the user has muted sounds at the app level.
///
/// **Known limitation:** macOS 14 does not expose Focus mode state to
/// third-party apps. Per-Focus configurations (Sleep, Do Not Disturb,
/// user-defined Focus) are not directly readable. The release runbook
/// documents this trade-off; the panel will still appear but with audio
/// when the user is in a Focus mode that the OS would otherwise mute.
enum DNDFilter {
    private static let logger = Logger(subsystem: "com.hanfour.peerdrop.mac", category: "DND")

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
