#if canImport(UIKit)
import UIKit

final class UIKitSystemInfoProvider: SystemInfoProvider {
    @MainActor
    var deviceModel: String { UIDevice.current.model }

    @MainActor
    var osVersion: String { UIDevice.current.systemVersion }
}
#endif
