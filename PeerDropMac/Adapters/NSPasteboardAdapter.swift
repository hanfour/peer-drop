#if canImport(AppKit)
import AppKit
import PeerDropPlatform

/// macOS adapter for `PlatformPasteboard`. Wraps `NSPasteboard.general`.
///
/// `NSPasteboard.changeCount` is the native equivalent of
/// `UIPasteboard.changeCount` — monotonically increasing whenever the
/// pasteboard contents change. AppKit does not emit a system notification
/// on pasteboard mutations, so `ClipboardSyncManager` runs a 2-second
/// poll that calls `checkPasteboardChange()` directly — no one posts the
/// `changedNotificationName` on macOS. The observer registered against it
/// is effectively dormant; the name exists only to satisfy the protocol.
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

    /// Effectively dormant on macOS — see the class-level doc. The protocol
    /// requires this property; ClipboardSyncManager's 2-second poll path
    /// drives change detection without going through NotificationCenter.
    var changedNotificationName: Notification.Name {
        Notification.Name("com.hanfour.peerdrop.mac.pasteboardChanged")
    }
}
#endif
