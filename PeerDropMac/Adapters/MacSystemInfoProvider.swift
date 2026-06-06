#if canImport(AppKit)
import AppKit
import Foundation
import PeerDropPlatform

/// macOS adapter for `SystemInfoProvider`.
///
/// `deviceModel` returns the sysctl `hw.model` identifier
/// (e.g. "Mac14,12" or "Macmini9,1") — the closest equivalent of
/// `UIDevice.current.model`. `osVersion` mirrors the iOS adapter by
/// returning `ProcessInfo.operatingSystemVersionString`
/// (e.g. "Version 14.5 (Build 23F79)").
final class MacSystemInfoProvider: SystemInfoProvider {
    @MainActor
    var deviceModel: String {
        var size: Int = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
            return "Mac"
        }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buf, &size, nil, 0) == 0 else {
            return "Mac"
        }
        return String(cString: buf)
    }

    @MainActor
    var osVersion: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }
}
#endif
