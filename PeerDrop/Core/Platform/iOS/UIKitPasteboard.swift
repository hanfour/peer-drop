#if canImport(UIKit)
import UIKit

final class UIKitPasteboard: PlatformPasteboard {
    private let pasteboard = UIPasteboard.general

    var changeCount: Int { pasteboard.changeCount }

    var stringContent: String? {
        get { pasteboard.string }
        set { pasteboard.string = newValue }
    }

    var imageContent: PlatformImage? {
        get { pasteboard.image }
        set { pasteboard.image = newValue }
    }

    var changedNotificationName: Notification.Name { UIPasteboard.changedNotification }
}
#endif
