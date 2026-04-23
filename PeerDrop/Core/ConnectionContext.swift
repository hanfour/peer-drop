import Foundation
import Combine

@MainActor
final class ConnectionContext: ObservableObject {
    @Published private(set) var hasTailscale: Bool = false
    @Published private(set) var tailnetPeerCount: Int = 0
    @Published private(set) var lastRelayFailure: Date?
    @Published private(set) var recentFailureRate: Double = 0
    @Published private(set) var knownDeviceSample: DeviceRecord?

    var primaryRecommendation: ConnectionRecommendation {
        if let rec = knownDeviceSample { return .useInviteKnownDevice(rec) }
        if hasTailscale && tailnetPeerCount > 0 { return .useTailnet(suggestedIP: nil) }
        if hasTailscale && tailnetPeerCount == 0 { return .useRelayCode }
        if !hasTailscale && recentFailureRate > 0.3 { return .configureTailscale }
        return .useRelayCode
    }

    func setKnownDeviceSample(_ rec: DeviceRecord?) { knownDeviceSample = rec }
    func setTailscaleState(hasTailscale: Bool, tailnetPeerCount: Int) {
        self.hasTailscale = hasTailscale; self.tailnetPeerCount = tailnetPeerCount
    }
    func setRecentFailureRate(_ rate: Double) { recentFailureRate = rate }
}

enum ConnectionRecommendation: Equatable {
    case useInviteKnownDevice(DeviceRecord)
    case useTailnet(suggestedIP: String?)
    case useRelayCode
    case useQRScan
    case configureTailscale
    case waitForDiscovery
}
