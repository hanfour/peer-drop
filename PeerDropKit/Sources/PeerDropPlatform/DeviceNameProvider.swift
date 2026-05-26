import Foundation

/// Returns the user-visible device name (iOS: "Hanfour's iPhone"; macOS:
/// "Hanfour's Mac mini" via Host.current().localizedName).
///
/// MainActor-isolated because the iOS adapter reads UIDevice.current which
/// is MainActor-bound in Swift 6. Call sites that are nonisolated/async
/// must wrap reads in `MainActor.run { ... }` (ConnectionManager line 2422
/// already does this).
public protocol DeviceNameProvider {
    @MainActor
    var currentName: String { get }
}
