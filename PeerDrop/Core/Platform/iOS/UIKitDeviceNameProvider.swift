#if canImport(UIKit)
import UIKit

final class UIKitDeviceNameProvider: DeviceNameProvider {
    @MainActor
    var currentName: String { UIDevice.current.name }
}
#endif
