import Foundation

/// Cross-platform pasteboard abstraction.
///
/// iOS implementation wraps `UIPasteboard.general`; macOS implementation
/// (M2) wraps `NSPasteboard.general`. Both platforms expose change-count
/// semantics that ClipboardSyncManager polls every 2 seconds.
public protocol PlatformPasteboard: AnyObject {
    /// Monotonically increasing counter; bumped by the system whenever
    /// pasteboard contents change.
    var changeCount: Int { get }

    /// Current string content if any.
    var stringContent: String? { get set }

    /// Current image content if any.
    var imageContent: PlatformImage? { get set }

    /// Notification name posted when pasteboard changes (iOS: UIPasteboard.changedNotification;
    /// macOS: synthesised via the 2s poll).
    var changedNotificationName: Notification.Name { get }
}
