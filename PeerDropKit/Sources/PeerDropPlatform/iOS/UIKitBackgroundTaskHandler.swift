#if canImport(UIKit)
import Foundation
import UIKit

@MainActor
final class UIKitBackgroundTaskHandler: BackgroundTaskHandling {
    init() {}

    func begin(expirationHandler: @escaping @Sendable () -> Void) -> BackgroundTaskToken {
        let id = UIApplication.shared.beginBackgroundTask(withName: "PeerDrop") {
            expirationHandler()
        }
        return BackgroundTaskToken(rawValue: id.rawValue)
    }

    func end(_ token: BackgroundTaskToken) {
        guard token != .invalid else { return }
        let id = UIBackgroundTaskIdentifier(rawValue: token.rawValue)
        UIApplication.shared.endBackgroundTask(id)
    }

    var backgroundTimeRemaining: TimeInterval {
        UIApplication.shared.backgroundTimeRemaining
    }
}
#endif
