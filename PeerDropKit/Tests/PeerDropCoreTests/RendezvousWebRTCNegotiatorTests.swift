import XCTest
@preconcurrency import WebRTC
import PeerDropTransport
@testable import PeerDropCore

@MainActor
final class RendezvousWebRTCNegotiatorTests: XCTestCase {

    func testConfigurationIsAllPolicyWithWorkerServersOrStunFallback() {
        let fallback = WebRTCRendezvousNegotiator.configuration(iceServers: [])
        XCTAssertEqual(fallback.iceTransportPolicy, .all)
        XCTAssertEqual(fallback.iceServers.flatMap(\.urlStrings),
                       ICEConfigurationProvider.stunServers.flatMap(\.urlStrings))
        let turn = RendezvousICEServer(urls: ["turn:t.example:3478"], username: "u", credential: "p")
        let c = WebRTCRendezvousNegotiator.configuration(iceServers: [turn])
        XCTAssertEqual(c.iceTransportPolicy, .all)
        XCTAssertEqual(c.iceServers.count, 1)
        XCTAssertEqual(c.iceServers[0].urlStrings, ["turn:t.example:3478"])
        XCTAssertEqual(c.iceServers[0].username, "u")
        XCTAssertEqual(c.iceServers[0].credential, "p")
    }

    /// Real WebRTC, in process: offer precedes its ICE, ICE before the remote
    /// description is queued, both sides open a data channel.
    func testLoopbackOffererAndAnswererOpen() async throws {
        let offerer = WebRTCRendezvousNegotiator(role: .offerer, iceServers: [])
        let answerer = WebRTCRendezvousNegotiator(role: .answerer, iceServers: [])
        var offererSent: [RendezvousSignal] = []
        var opened: [String] = []
        offerer.onLocalSignal = { s in
            offererSent.append(s)
            DispatchQueue.main.async { answerer.handleRemote(s) }
        }
        answerer.onLocalSignal = { s in DispatchQueue.main.async { offerer.handleRemote(s) } }
        offerer.onOpen = { _ in opened.append("o") }
        answerer.onOpen = { _ in opened.append("a") }
        offerer.onClosed = { XCTFail("offerer closed") }
        answerer.onClosed = { XCTFail("answerer closed") }
        answerer.start()
        offerer.start()
        await rvWaitUntil(timeout: 20) { opened.count == 2 }
        if case .offer = offererSent.first {} else { XCTFail("first local signal must be the offer: \(offererSent.first.map { "\($0)" } ?? "none")") }
        offerer.close()
        answerer.close()
    }
}
