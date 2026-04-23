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

    private var subs = Set<AnyCancellable>()

    func setKnownDeviceSample(_ rec: DeviceRecord?) { knownDeviceSample = rec }
    func setTailscaleState(hasTailscale: Bool, tailnetPeerCount: Int) {
        self.hasTailscale = hasTailscale; self.tailnetPeerCount = tailnetPeerCount
    }
    func setRecentFailureRate(_ rate: Double) { recentFailureRate = rate }

    // MARK: - Live Signal Wiring

    func observe(deviceStore: DeviceRecordStore, tailnetStore: TailnetPeerStore) {
        deviceStore.$records.sink { [weak self] records in
            let best = records.filter { $0.peerDeviceId != nil }
                              .sorted { $0.lastConnected > $1.lastConnected }
                              .first
            self?.setKnownDeviceSample(best)
        }.store(in: &subs)

        tailnetStore.$entries.sink { [weak self] _ in
            let reachable = tailnetStore.entries.filter { tailnetStore.isReachable($0.id) }.count
            self?.setTailscaleState(hasTailscale: Self.detectTailscale(), tailnetPeerCount: reachable)
        }.store(in: &subs)
    }

    private static func detectTailscale() -> Bool {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return false }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let i = ptr.pointee
            let name = String(cString: i.ifa_name)
            guard let addr = i.ifa_addr else { continue }
            guard name.hasPrefix("utun"),
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                        &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            if String(cString: host).hasPrefix("100.") { return true }
        }
        return false
    }
}

enum ConnectionRecommendation: Equatable {
    case useInviteKnownDevice(DeviceRecord)
    case useTailnet(suggestedIP: String?)
    case useRelayCode
    case useQRScan
    case configureTailscale
    case waitForDiscovery
}
