#if canImport(AppKit)
import AppKit
import PeerDropPlatform

/// macOS adapter for `DeviceNameProvider`.
///
/// Returns the user-visible device name (e.g. "Hanfour's Mac mini") via
/// `Host.current().localizedName`. Falls back through `Host.current().name`
/// (no localisation) and then a hardcoded "Mac" if the system returns nothing.
final class HostDeviceNameProvider: DeviceNameProvider {
    @MainActor
    var currentName: String {
        Host.current().localizedName ?? Host.current().name ?? "Mac"
    }
}
#endif
