#if os(iOS)
import Foundation
import UIKit

@MainActor
public final class UIKitBackgroundTaskHandler: BackgroundTaskHandling {
    public init() {}

    public func begin(expirationHandler: @escaping @Sendable () -> Void) -> BackgroundTaskToken {
        let id = UIApplication.shared.beginBackgroundTask(withName: "PeerDrop") {
            expirationHandler()
        }
        return BackgroundTaskToken(rawValue: id.rawValue)
    }

    public func end(_ token: BackgroundTaskToken) {
        guard token != .invalid else { return }
        let id = UIBackgroundTaskIdentifier(rawValue: token.rawValue)
        UIApplication.shared.endBackgroundTask(id)
    }

    public var backgroundTimeRemaining: TimeInterval {
        UIApplication.shared.backgroundTimeRemaining
    }
}
#endif
