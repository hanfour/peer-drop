import XCTest
@testable import PeerDrop

@MainActor
final class ConnectionContextTests: XCTestCase {
    func test_knownDeviceWithPeerDeviceId_returnsInviteKnownDevice() {
        let ctx = ConnectionContext()
        let rec = DeviceRecord(id: "a", displayName: "Alice", sourceType: "relay",
                               lastConnected: Date(), connectionCount: 3,
                               peerDeviceId: "dev-abc")
        ctx.setKnownDeviceSample(rec)
        if case .useInviteKnownDevice = ctx.primaryRecommendation { } else { XCTFail("Expected .useInviteKnownDevice") }
    }

    func test_tailscaleWithPeers_returnsUseTailnet() {
        let ctx = ConnectionContext()
        ctx.setTailscaleState(hasTailscale: true, tailnetPeerCount: 3)
        if case .useTailnet = ctx.primaryRecommendation { } else { XCTFail("Expected .useTailnet") }
    }

    func test_tailscaleWithoutPeers_returnsUseRelayCode() {
        let ctx = ConnectionContext()
        ctx.setTailscaleState(hasTailscale: true, tailnetPeerCount: 0)
        if case .useRelayCode = ctx.primaryRecommendation { } else { XCTFail("Expected .useRelayCode") }
    }

    func test_highFailureRate_returnsConfigureTailscale() {
        let ctx = ConnectionContext()
        ctx.setTailscaleState(hasTailscale: false, tailnetPeerCount: 0)
        ctx.setRecentFailureRate(0.5)
        if case .configureTailscale = ctx.primaryRecommendation { } else { XCTFail("Expected .configureTailscale") }
    }

    func test_defaultFallback_returnsUseRelayCode() {
        let ctx = ConnectionContext()
        if case .useRelayCode = ctx.primaryRecommendation { } else { XCTFail("Expected .useRelayCode") }
    }
}
