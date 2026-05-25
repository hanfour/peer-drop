import Foundation

public struct PlatformDependencies {
    public var pasteboard: () -> PlatformPasteboard

    public init(
        pasteboard: (() -> PlatformPasteboard)? = nil
    ) {
        self.pasteboard = pasteboard ?? { PlatformDependencies.makePasteboard() }
    }

    public static var shared = PlatformDependencies()

    // Default factories — iOS adapter on iOS, falls back to a no-op on
    // other platforms until M2 wires AppKit adapters.
    private static func makePasteboard() -> PlatformPasteboard {
        #if canImport(UIKit)
        return UIKitPasteboard()
        #else
        return NoOpPasteboard()
        #endif
    }
}

#if !canImport(UIKit)
private final class NoOpPasteboard: PlatformPasteboard {
    var changeCount: Int { 0 }
    var stringContent: String? { get { nil } set { } }
    var imageContent: PlatformImage? { get { nil } set { } }
    var changedNotificationName: Notification.Name { Notification.Name("NoOpPasteboardChanged") }
}
#endif
