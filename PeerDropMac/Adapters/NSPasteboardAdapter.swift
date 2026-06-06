#if canImport(AppKit)
import AppKit
import PeerDropPlatform

/// macOS adapter for `PlatformPasteboard`. Wraps `NSPasteboard.general`.
///
/// `NSPasteboard.changeCount` is the native equivalent of
/// `UIPasteboard.changeCount` — monotonically increasing whenever the
/// pasteboard contents change. `ClipboardSyncManager` polls this every
/// 2 seconds (per the protocol doc comment) and synthesises a
/// `changedNotificationName` post itself; AppKit does not emit a system
/// notification on pasteboard mutations.
final class NSPasteboardAdapter: PlatformPasteboard {
    private let pasteboard = NSPasteboard.general

    var changeCount: Int { pasteboard.changeCount }

    var stringContent: String? {
        get { pasteboard.string(forType: .string) }
        set {
            pasteboard.clearContents()
            if let newValue {
                pasteboard.setString(newValue, forType: .string)
            }
        }
    }

    var imageContent: PlatformImage? {
        get {
            pasteboard.readObjects(forClasses: [NSImage.self])?.first as? NSImage
        }
        set {
            pasteboard.clearContents()
            if let newValue {
                pasteboard.writeObjects([newValue])
            }
        }
    }

    /// macOS has no system notification for pasteboard changes; ClipboardSyncManager
    /// polls `changeCount` and posts this name itself when a diff is detected.
    var changedNotificationName: Notification.Name {
        Notification.Name("com.hanfour.peerdrop.mac.pasteboardChanged")
    }
}
#endif
