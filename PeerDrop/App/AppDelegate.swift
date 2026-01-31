import UIKit
import CallKit

class AppDelegate: NSObject, UIApplicationDelegate {
    var callKitManager: CallKitManager?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        callKitManager = CallKitManager()
        return true
    }
}
