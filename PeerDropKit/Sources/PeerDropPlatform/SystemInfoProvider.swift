import Foundation

/// System telemetry for error reports. Both fields ship to the Cloudflare
/// Worker `/debug/report` endpoint as plain strings.
public protocol SystemInfoProvider {
    @MainActor
    var deviceModel: String { get }

    @MainActor
    var osVersion: String { get }
}
