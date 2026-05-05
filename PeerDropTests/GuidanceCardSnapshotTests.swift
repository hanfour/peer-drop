import XCTest
import SwiftUI
@testable import PeerDrop

@MainActor
final class GuidanceCardSnapshotTests: XCTestCase {
    func test_rendersNonEmpty_whenContextHasKnownDevice() {
        let ctx = ConnectionContext()
        let rec = DeviceRecord(id: "a", displayName: "Alice",
                                sourceType: "relay", lastConnected: Date(),
                                connectionCount: 1, peerDeviceId: "d")
        ctx.setKnownDeviceSample(rec)
        let card = GuidanceCard(onMoreOptions: {}, onDismiss: nil)
            .environmentObject(ctx)
            .environmentObject(ConnectionManager())
        let host = UIHostingController(rootView: card)
        host.view.frame = CGRect(x: 0, y: 0, width: 375, height: 200)
        host.view.layoutIfNeeded()
        XCTAssertGreaterThan(host.view.intrinsicContentSize.height, 0)
    }

    func test_rendersNonEmpty_whenContextHasTailnetPeers() {
        let ctx = ConnectionContext()
        ctx.setTailscaleState(hasTailscale: true, tailnetPeerCount: 2)
        let card = GuidanceCard(onMoreOptions: {}, onDismiss: nil)
            .environmentObject(ctx)
            .environmentObject(ConnectionManager())
        let host = UIHostingController(rootView: card)
        host.view.frame = CGRect(x: 0, y: 0, width: 375, height: 200)
        host.view.layoutIfNeeded()
        XCTAssertGreaterThan(host.view.intrinsicContentSize.height, 0)
    }

    func test_rendersNonEmpty_inEmptyContext() {
        let ctx = ConnectionContext()
        let card = GuidanceCard(onMoreOptions: {}, onDismiss: nil)
            .environmentObject(ctx)
            .environmentObject(ConnectionManager())
        let host = UIHostingController(rootView: card)
        host.view.frame = CGRect(x: 0, y: 0, width: 375, height: 200)
        host.view.layoutIfNeeded()
        XCTAssertGreaterThan(host.view.intrinsicContentSize.height, 0)
    }

    func test_rendersNonEmpty_whenContextHasHighFailureRate() {
        let ctx = ConnectionContext()
        ctx.setRecentFailureRate(0.5)
        let card = GuidanceCard(onMoreOptions: {}, onDismiss: nil)
            .environmentObject(ctx)
            .environmentObject(ConnectionManager())
        let host = UIHostingController(rootView: card)
        host.view.frame = CGRect(x: 0, y: 0, width: 375, height: 200)
        host.view.layoutIfNeeded()
        XCTAssertGreaterThan(host.view.intrinsicContentSize.height, 0)
    }
}
