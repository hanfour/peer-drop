import XCTest
import CryptoKit
import PeerDropSecurity
@testable import PeerDropCore

@MainActor
final class RendezvousSignalingClientTests: XCTestCase {

    let base = URL(string: "https://rv.example.test")!
    let day = 20_833
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var me: RendezvousTestIdentity!
    var peer: RVPeer!
    var token: Data!
    var tags: RendezvousSessionTagStore!
    var factory: FakeRVSocketFactory!
    var http: FakeRVHTTP!
    var events: [RendezvousSignalingEvent] = []
    /// The socket only holds the client weakly (the manager owns it in production).
    var clients: [RendezvousSignalingClient] = []

    override func setUp() async throws {
        me = RendezvousTestIdentity()
        peer = RVPeer()
        token = try RendezvousToken.token(provider: IdentityRendezvousSecretProvider(identity: me), peerKey: peer.key, day: day)
        tags = RendezvousSessionTagStore()
        factory = FakeRVSocketFactory()
        http = FakeRVHTTP()
        events = []
        clients = []
    }

    func makeClient(solver: RendezvousPoWSolving = DetachedRendezvousPoWSolver()) -> RendezvousSignalingClient {
        let c = RendezvousSignalingClient(
            token: token, day: day, peerKey: peer.key, provider: IdentityRendezvousSecretProvider(identity: me),
            sessionTags: tags, baseURL: base, socketFactory: factory, http: http, solver: solver,
            clock: { [unowned self] in self.now })
        c.onEvent = { [unowned self] in self.events.append($0) }
        clients.append(c)
        return c
    }

    func connected(solver: RendezvousPoWSolving = DetachedRendezvousPoWSolver()) async -> (RendezvousSignalingClient, FakeRVSocket) {
        let c = makeClient(solver: solver)
        c.connect()
        await rvWaitUntil { self.factory.sockets.count == 1 }
        return (c, factory.sockets[0])
    }

    /// joined + our hello + peer hello ⇒ both sides hold a cipher.
    func handshaken() async throws -> (RendezvousSignalingClient, FakeRVSocket) {
        let (c, s) = await connected()
        s.deliver(#"{"t":"joined"}"#)
        let ourHello = try XCTUnwrap(s.sent.last)
        let peerHello = try peer.hello(towards: me.raw, day: day)
        try peer.accept(ourHello)
        s.deliver(peerHello)
        XCTAssertEqual(events, [.peerJoined, .handshakeCompleted])
        return (c, s)
    }

    // MARK: First frame

    func testFirstFrameShapeTokenOnlyInFrame() async throws {
        let (_, s) = await connected()
        XCTAssertEqual(s.url.absoluteString, "wss://rv.example.test/rv", "token never in the URL")
        XCTAssertEqual(s.sent.count, 1)
        let frame = s.sent[0]
        XCTAssertLessThanOrEqual(frame.utf8.count, RendezvousFirstFrame.maxFrameBytes)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), ["v", "t", "pow", "s"])
        XCTAssertEqual(obj["v"] as? Int, 1)
        XCTAssertEqual(obj["t"] as? String, try RendezvousToken.encoded(token))
        XCTAssertEqual(obj["s"] as? String, tags.tag(for: token))
        let pow = try XCTUnwrap(obj["pow"] as? [String: Any])
        let h = try XCTUnwrap(pow["h"] as? Int), n = try XCTUnwrap(pow["n"] as? String)
        XCTAssertTrue(RendezvousProofOfWork.verifyClaim(tokenBytes: token, hour: h, nonce: n, now: now))
        XCTAssertTrue(frame.hasPrefix(#"{"v":1,"t":""#))
    }

    func testPoWIsSolvedOffTheMainThread() async {
        let box = ThreadBox()
        let solver = DetachedRendezvousPoWSolver(threadObserver: { box.record($0) })
        _ = await connected(solver: solver)
        XCTAssertEqual(box.values, [false], "PoW must never run on the main thread")
    }

    func testSameTagForReconnectToSameToken() async {
        let (c1, s1) = await connected()
        c1.close()
        let c2 = makeClient()
        c2.connect()
        await rvWaitUntil { self.factory.sockets.count == 2 }
        func s(_ frame: String) -> String? {
            (try? JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])?["s"] as? String
        }
        XCTAssertEqual(s(s1.sent[0]), s(factory.sockets[1].sent[0]))
    }

    // MARK: Keepalive

    func testPingCadenceWithInjectedClock() async {
        let (c, s) = await connected()
        let t0 = now
        func pings() -> Int { s.sent.filter { $0 == "ping" }.count }
        c.tick(now: t0.addingTimeInterval(24.9)); XCTAssertEqual(pings(), 0)
        c.tick(now: t0.addingTimeInterval(25)); XCTAssertEqual(pings(), 1)
        c.tick(now: t0.addingTimeInterval(49.9)); XCTAssertEqual(pings(), 1)
        c.tick(now: t0.addingTimeInterval(50)); XCTAssertEqual(pings(), 2)
        XCTAssertLessThanOrEqual(RendezvousSignalingClient.pingInterval, 30)
        c.close()
        c.tick(now: t0.addingTimeInterval(100)); XCTAssertEqual(pings(), 2, "no ping after close")
        // "pong" (DO auto-response) is ignored.
        s.deliver("pong")
        XCTAssertEqual(events, [])
    }

    // MARK: Hello rules

    func testNoHelloBeforeJoinedAndPeerHelloBeforeJoinedDropped() async throws {
        let (_, s) = await connected()
        s.deliver(try peer.hello(towards: me.raw, day: day))
        XCTAssertEqual(s.sent.count, 1, "only the first frame")
        XCTAssertEqual(events, [])
        s.deliver(#"{"t":"joined"}"#)
        XCTAssertEqual(s.sent.count, 2)
        XCTAssertNotNil(RendezvousHello.parse(s.sent[1]))
        XCTAssertEqual(events, [.peerJoined])
    }

    func testSealedWrapAndRoundTrip() async throws {
        let (c, s) = try await handshaken()
        c.sendSignal(Data("hi".utf8))
        let frame = try XCTUnwrap(s.sent.last)
        XCTAssertTrue(frame.hasPrefix(#"{"t":"sig","c":""#))
        XCTAssertEqual(peer.open(frame), Data("hi".utf8))
        s.deliver(try peer.sealFrame(Data("yo".utf8)))
        XCTAssertEqual(events.last, .signal(Data("yo".utf8)))
    }

    func testSendSignalBeforeHandshakeSendsNothing() async {
        let (c, s) = await connected()
        c.sendSignal(Data("x".utf8))
        s.deliver(#"{"t":"joined"}"#)
        c.sendSignal(Data("x".utf8))
        XCTAssertFalse(s.sent.contains { $0.contains(#""t":"sig""#) })
    }

    func testExtraHelloAfterCompletionIsDroppedNeverRebinds() async throws {
        let (_, s) = try await handshaken()
        let intruder = RVPeer()
        s.deliver(try intruder.hello(towards: me.raw, day: day))
        // Another hello from the real peer's fresh handshake is dropped too.
        XCTAssertEqual(events, [.peerJoined, .handshakeCompleted])
        // The original cipher still works.
        s.deliver(try peer.sealFrame(Data("still".utf8)))
        XCTAssertEqual(events.last, .signal(Data("still".utf8)))
    }

    func testFirstSealedFrameAEADFailureClosesSocket() async throws {
        let (c, s) = try await handshaken()
        let other = RVPeer()
        _ = try other.hello(towards: me.raw, day: day)
        try other.accept(try peer.hello(towards: other.key, day: day))  // any foreign cipher
        s.deliver(try other.sealFrame(Data("forged".utf8)))
        XCTAssertTrue(s.closedByClient)
        XCTAssertEqual(events.last, .closed)
        XCTAssertFalse(c.hasCipher)
        // Nothing more is processed or sent.
        let sentCount = s.sent.count
        s.deliver(#"{"t":"joined"}"#)
        c.sendSignal(Data("x".utf8))
        XCTAssertEqual(s.sent.count, sentCount)
        XCTAssertEqual(events.filter { $0 == .closed }.count, 1)
    }

    func testMalformedFirstSealedFrameAlsoCloses() async throws {
        let (_, s) = try await handshaken()
        s.deliver(#"{"t":"sig","c":"!!!"}"#)
        XCTAssertTrue(s.closedByClient)
        XCTAssertEqual(events.last, .closed)
    }

    func testLaterAEADFailureDropsFrameAndKeepsCipher() async throws {
        let (c, s) = try await handshaken()
        let first = try peer.sealFrame(Data("one".utf8))
        s.deliver(first)
        XCTAssertEqual(events.last, .signal(Data("one".utf8)))
        // Tampered frame → dropped.
        var tampered = try peer.sealFrame(Data("two".utf8))
        tampered = tampered.replacingOccurrences(of: #""}"#, with: #"A"}"#)
        s.deliver(tampered)
        // Replay (stale counter) → dropped.
        s.deliver(first)
        XCTAssertFalse(s.closedByClient)
        XCTAssertTrue(c.hasCipher)
        XCTAssertEqual(events.count, 3)
        // Cipher was not reset: the next counter still opens.
        s.deliver(try peer.sealFrame(Data("three".utf8)))
        XCTAssertEqual(events.last, .signal(Data("three".utf8)))
    }

    func testReplayedOldOfferFromPreviousSessionFailsAndCloses() async throws {
        let (_, s) = try await handshaken()
        let oldHello = try XCTUnwrap(peer.handshake?.helloFrame)
        let oldOffer = try peer.sealFrame(RendezvousSignal.offer(sdp: "old").encoded())
        // Peer reconnects: left + joined ⇒ fresh handshake with a fresh local r.
        s.deliver(#"{"t":"left"}"#)
        s.deliver(#"{"t":"joined"}"#)
        // The operator replays the old hello and the old sealed offer.
        s.deliver(oldHello)
        s.deliver(oldOffer)
        XCTAssertTrue(s.closedByClient)
        XCTAssertEqual(events.suffix(4), [.peerLeft, .peerJoined, .handshakeCompleted, .closed])
        XCTAssertFalse(events.contains(.signal(RendezvousSignal.offer(sdp: "old").encoded())))
    }

    func testControlFramesAreOnlyHints() async throws {
        let (c, s) = try await handshaken()
        // Variants that are not the exact control frames are not control frames.
        s.deliver(#"{"t":"joined","x":1}"#)
        s.deliver(#"{ "t":"left" }"#)
        s.deliver("garbage")
        s.deliver(#"{"t":"ping"}"#)
        XCTAssertEqual(events, [.peerJoined, .handshakeCompleted])
        XCTAssertTrue(c.hasCipher)
        // `left` drops the cipher (peer gone) but keeps the socket open.
        s.deliver(#"{"t":"left"}"#)
        XCTAssertFalse(s.closedByClient)
        XCTAssertFalse(c.hasCipher)
        // Old-session sealed frames after `left` are ignored, not fatal.
        s.deliver(try peer.sealFrame(Data("late".utf8)))
        XCTAssertFalse(s.closedByClient)
        XCTAssertEqual(events.last, .peerLeft)
    }

    func testOversizeInboundFrameDropped() async throws {
        let (_, s) = try await handshaken()
        s.deliver(#"{"t":"sig","c":""# + String(repeating: "A", count: 70_000) + #""}"#)
        XCTAssertFalse(s.closedByClient)
    }

    // MARK: Unreachable mapping

    func testAnyRemoteCloseIsOneClosedEvent() async throws {
        let (_, s) = try await handshaken()
        s.remoteClose()
        s.remoteClose()
        XCTAssertEqual(events.filter { $0 == .closed }.count, 1)
    }

    func testPoWFailureMapsToTheSameClosedEvent() async {
        let c = makeClient(solver: FailingRVSolver())
        c.connect()
        await rvWaitUntil { !self.events.isEmpty }
        XCTAssertEqual(events, [.closed])
        XCTAssertTrue(factory.sockets.isEmpty)
    }

    func testExplicitCloseEmitsNothing() async {
        let (c, s) = await connected()
        c.close()
        s.remoteClose()
        XCTAssertTrue(s.closedByClient)
        XCTAssertEqual(events, [])
    }

    func testCloseDuringPoWNeverOpensSocket() async {
        let c = makeClient()
        c.connect()
        c.close()
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(factory.sockets.isEmpty)
        XCTAssertEqual(events, [])
    }

    // MARK: ICE

    func testICEFetchBodyReusesPoWAndParsesServers() async throws {
        let solver = CountingRVSolver()
        let (c, _) = await connected(solver: solver)
        http.result = .success((Data("""
        {"iceServers":[{"urls":["stun:stun.cloudflare.com:3478"]},
         {"urls":["turn:turn.cloudflare.com:3478?transport=udp","https://bad"],"username":"u","credential":"p"},
         {"urls":["http://nope"]}]}
        """.utf8), 200))
        let servers = await c.fetchICEServers()
        XCTAssertEqual(servers, [
            RendezvousICEServer(urls: ["stun:stun.cloudflare.com:3478"]),
            RendezvousICEServer(urls: ["turn:turn.cloudflare.com:3478?transport=udp"], username: "u", credential: "p"),
        ])
        XCTAssertEqual(solver.calls, 1, "same hour ⇒ PoW reused")
        let (url, body) = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(url.absoluteString, "https://rv.example.test/rv/ice")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), ["t", "pow"])
        XCTAssertEqual(obj["t"] as? String, try RendezvousToken.encoded(token))
        let pow = try XCTUnwrap(obj["pow"] as? [String: Any])
        XCTAssertTrue(RendezvousProofOfWork.verifyClaim(tokenBytes: token, hour: pow["h"] as! Int, nonce: pow["n"] as! String, now: now))
        // Next hour ⇒ re-solved.
        now = now.addingTimeInterval(3600)
        _ = await c.fetchICEServers()
        XCTAssertEqual(solver.calls, 2)
    }

    func testICEFailuresFallBackToEmpty() async {
        let (c, _) = await connected()
        http.result = .success((Data(#"{"error":"denied"}"#.utf8), 403))
        let denied = await c.fetchICEServers()
        XCTAssertEqual(denied, [])
        http.result = .failure(URLError(.notConnectedToInternet))
        let offline = await c.fetchICEServers()
        XCTAssertEqual(offline, [])
        http.result = .success((Data("nope".utf8), 200))
        let garbage = await c.fetchICEServers()
        XCTAssertEqual(garbage, [])
        XCTAssertEqual(events, [], "ICE failure is not a signaling failure")
    }
}

final class ThreadBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Bool] = []
    func record(_ v: Bool) { lock.lock(); _values.append(v); lock.unlock() }
    var values: [Bool] { lock.lock(); defer { lock.unlock() }; return _values }
}
