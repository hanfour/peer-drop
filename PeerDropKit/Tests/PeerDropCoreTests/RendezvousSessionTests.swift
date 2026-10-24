import XCTest
@testable import PeerDropCore

final class RendezvousSessionTests: XCTestCase {

    typealias S = RendezvousSession
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    let token = Data(repeating: 7, count: 32)
    let contact = UUID()

    func at(_ s: TimeInterval) -> Date { base.addingTimeInterval(s) }
    let ready = RendezvousSignal.ready.encoded()

    // MARK: Fixtures (all built at `base`)

    func idle(role: RendezvousRole = .offerer) -> S {
        S(contactID: contact, day: 1, token: token, role: role, isForeground: false, isEnabled: true)
    }

    func waiting(role: RendezvousRole = .offerer) -> S {
        var s = S(contactID: contact, day: 1, token: token, role: role, isForeground: true, isEnabled: false)
        XCTAssertEqual(s.handle(.enabled, now: base), [.joinRoom(token: token)])
        return s
    }

    /// Peer present, handshake done, peer authenticated (offerer waits on nothing).
    func waitingAuthenticatedAnswerer() -> S {
        var s = waiting(role: .answerer)
        _ = s.handle(.peerJoined, now: base)
        _ = s.handle(.signalingReady, now: base)
        XCTAssertEqual(s.handle(.signal(ready), now: base), [])
        return s
    }

    func negotiating() -> S {
        var s = waiting()
        _ = s.handle(.peerJoined, now: base)
        XCTAssertEqual(s.handle(.signalingReady, now: base), [.sendSignal(ready)])
        XCTAssertEqual(s.handle(.signal(ready), now: base), [.startNegotiation(.offerer, attempt: 1)])
        return s
    }

    func connected() -> S {
        var s = negotiating()
        XCTAssertEqual(s.handle(.dataChannelOpen, now: base), [.installConnection(attempt: 1)])
        return s
    }

    func secured() -> S {
        var s = connected()
        XCTAssertEqual(s.handle(.secureChannelResult(ok: true), now: base), [.leaveRoom])
        return s
    }

    func failed() -> S {
        var s = waiting()
        XCTAssertEqual(s.handle(.signalingClosed, now: base), [.scheduleRetry(at: at(1))])
        return s
    }

    func closed() -> S {
        var s = waiting()
        _ = s.handle(.disabled, now: base)
        return s
    }

    // MARK: - Full state × event table

    struct Row {
        let fixture: String
        let event: S.Event
        let state: S.State
        let actions: [S.Action]
        let line: UInt
    }

    func testStateEventTable() {
        let fixtures: [String: () -> S] = [
            "idle": { self.idle() }, "waiting": { self.waiting() }, "negotiating": { self.negotiating() },
            "connected": { self.connected() }, "secured": { self.secured() }, "failed": { self.failed() },
            "closed": { self.closed() },
        ]
        let fail = S.Event.secureChannelResult(ok: false)
        let ok = S.Event.secureChannelResult(ok: true)
        let sig = S.Event.signal(ready)
        let retry1 = S.Action.scheduleRetry(at: at(1 + 1))
        // `now` for every row is base+1.
        func r(_ f: String, _ e: S.Event, _ st: S.State, _ a: [S.Action], line: UInt = #line) -> Row {
            Row(fixture: f, event: e, state: st, actions: a, line: line)
        }
        let rows: [Row] = [
            // idle (background, enabled)
            r("idle", .appForeground, .waiting, [.joinRoom(token: token)]),
            r("idle", .appBackground, .idle, []),
            r("idle", .enabled, .idle, []),
            r("idle", .disabled, .closed, []),
            r("idle", .peerJoined, .idle, []),
            r("idle", .peerLeft, .idle, []),
            r("idle", sig, .idle, []),
            r("idle", .dataChannelOpen, .idle, []),
            r("idle", ok, .idle, []),
            r("idle", fail, .idle, []),
            r("idle", .tick, .idle, []),
            // waiting (alone in the room)
            r("waiting", .appForeground, .waiting, []),
            r("waiting", .appBackground, .idle, [.leaveRoom]),
            r("waiting", .enabled, .waiting, []),
            r("waiting", .disabled, .closed, [.leaveRoom]),
            r("waiting", .peerJoined, .waiting, []),
            r("waiting", .peerLeft, .waiting, []),
            r("waiting", sig, .waiting, []),
            r("waiting", .dataChannelOpen, .waiting, []),
            r("waiting", ok, .waiting, []),
            r("waiting", fail, .waiting, []),
            r("waiting", .tick, .waiting, []),
            // negotiating (offerer)
            r("negotiating", .appForeground, .negotiating, []),
            r("negotiating", .appBackground, .idle, [.closeConnection, .leaveRoom]),
            r("negotiating", .enabled, .negotiating, []),
            r("negotiating", .disabled, .closed, [.closeConnection, .leaveRoom]),
            r("negotiating", .peerJoined, .waiting, [.closeConnection]),
            r("negotiating", .peerLeft, .waiting, [.closeConnection]),
            r("negotiating", sig, .negotiating, []),
            r("negotiating", .dataChannelOpen, .connected, [.installConnection(attempt: 1)]),
            r("negotiating", ok, .negotiating, []),
            r("negotiating", fail, .negotiating, []),
            r("negotiating", .tick, .negotiating, []),
            // connected, secure channel pending
            r("connected", .appForeground, .connected, []),
            r("connected", .appBackground, .idle, [.closeConnection, .leaveRoom]),
            r("connected", .enabled, .connected, []),
            r("connected", .disabled, .closed, [.closeConnection, .leaveRoom]),
            r("connected", .peerJoined, .connected, []),
            r("connected", .peerLeft, .connected, []),
            r("connected", sig, .connected, []),
            r("connected", .dataChannelOpen, .connected, []),
            r("connected", ok, .connected, [.leaveRoom]),
            r("connected", fail, .failed(.secureChannelFailed), [.closeConnection, .leaveRoom, retry1]),
            r("connected", .tick, .connected, []),
            // connected + secured (signaling socket already left)
            r("secured", .appForeground, .connected, []),
            r("secured", .appBackground, .idle, [.closeConnection]),
            r("secured", .enabled, .connected, []),
            r("secured", .disabled, .closed, [.closeConnection]),
            r("secured", .peerJoined, .connected, []),
            r("secured", .peerLeft, .connected, []),
            r("secured", sig, .connected, []),
            r("secured", .dataChannelOpen, .connected, []),
            r("secured", ok, .connected, []),
            r("secured", fail, .connected, []),
            r("secured", .tick, .connected, []),
            // failed (retry due at base+1)
            r("failed", .appForeground, .failed(.signalingClosed), []),
            r("failed", .appBackground, .idle, []),
            r("failed", .enabled, .failed(.signalingClosed), []),
            r("failed", .disabled, .closed, []),
            r("failed", .peerJoined, .failed(.signalingClosed), []),
            r("failed", .peerLeft, .failed(.signalingClosed), []),
            r("failed", sig, .failed(.signalingClosed), []),
            r("failed", .dataChannelOpen, .failed(.signalingClosed), []),
            r("failed", ok, .failed(.signalingClosed), []),
            r("failed", fail, .failed(.signalingClosed), []),
            r("failed", .tick, .waiting, [.joinRoom(token: token)]),
            // closed is terminal
            r("closed", .appForeground, .closed, []),
            r("closed", .appBackground, .closed, []),
            r("closed", .enabled, .closed, []),
            r("closed", .disabled, .closed, []),
            r("closed", .peerJoined, .closed, []),
            r("closed", .peerLeft, .closed, []),
            r("closed", sig, .closed, []),
            r("closed", .dataChannelOpen, .closed, []),
            r("closed", ok, .closed, []),
            r("closed", fail, .closed, []),
            r("closed", .tick, .closed, []),
        ]
        XCTAssertEqual(rows.count, 7 * 11)
        for row in rows {
            var s = fixtures[row.fixture]!()
            let actions = s.handle(row.event, now: at(1))
            XCTAssertEqual(actions, row.actions, "\(row.fixture) × \(row.event)", line: row.line)
            XCTAssertEqual(s.state, row.state, "\(row.fixture) × \(row.event)", line: row.line)
        }
    }

    /// Every remaining event × every state is defined (never traps) and the
    /// closing events never emit a frame.
    func testExtraEventsNeverSendFramesOnClosingPaths() {
        let all: [() -> S] = [{ self.idle() }, { self.waiting() }, { self.negotiating() }, { self.connected() },
                              { self.secured() }, { self.failed() }, { self.closed() }, { self.waitingAuthenticatedAnswerer() }]
        let closing: [S.Event] = [.disabled, .appBackground, .retire, .directConnectionPresent]
        for make in all {
            for e in closing {
                var s = make()
                let actions = s.handle(e, now: at(1))
                XCTAssertTrue(actions.allSatisfy { $0 == .leaveRoom || $0 == .closeConnection }, "\(e): \(actions)")
                // And nothing afterwards can revive a frame for disabled/retire/direct.
                if e != .appBackground {
                    XCTAssertEqual(s.state, .closed)
                    for later in [S.Event.peerJoined, .signalingReady, .signal(ready), .tick, .enabled, .appForeground] {
                        XCTAssertEqual(s.handle(later, now: at(100)), [])
                    }
                }
            }
        }
    }

    // MARK: - Downgrade

    func testDowngradeFromAuthenticatedWaitingEmitsOnlyLeaveRoom() {
        var s = waitingAuthenticatedAnswerer()
        XCTAssertEqual(s.handle(.disabled, now: at(1)), [.leaveRoom])
        XCTAssertEqual(s.state, .closed)
    }

    func testDowngradeWhileConnectingDoesNotSendAnySignal() {
        var s = negotiating()
        let a = s.handle(.disabled, now: at(1))
        XCTAssertFalse(a.contains { if case .sendSignal = $0 { return true } else { return false } })
        XCTAssertEqual(a, [.closeConnection, .leaveRoom])
    }

    // MARK: - Hello / authentication rules

    func testReadyIsSentOnlyAfterJoinedAndHandshake() {
        var s = waiting()
        XCTAssertEqual(s.handle(.signalingReady, now: base), [], "no ready before joined")
        _ = s.handle(.peerJoined, now: base)
        XCTAssertEqual(s.handle(.signalingReady, now: base), [.sendSignal(ready)])
        XCTAssertEqual(s.handle(.signalingReady, now: base), [], "one ready per handshake")
    }

    func testThirdPartyJoinWithoutSealedFramesTimesOutAtExactlyFiveSeconds() {
        var s = waiting()
        _ = s.handle(.peerJoined, now: base)
        _ = s.handle(.signalingReady, now: base)  // a hello from someone without the DH
        XCTAssertEqual(s.handle(.tick, now: at(4.999)), [])
        XCTAssertEqual(s.state, .waiting)
        let a = s.handle(.tick, now: at(5), context: .init(jitter: 3))
        XCTAssertEqual(a, [.leaveRoom, .scheduleRetry(at: at(5 + 1 + 3))])
        XCTAssertEqual(s.state, .failed(.signalingTimeout))
    }

    func testJoinedWithoutHelloAlsoTimesOut() {
        var s = waiting()
        _ = s.handle(.peerJoined, now: base)
        XCTAssertEqual(s.handle(.tick, now: at(5)), [.leaveRoom, .scheduleRetry(at: at(6))])
    }

    func testValidSealedFrameClearsSignalingDeadline() {
        var s = waitingAuthenticatedAnswerer()
        XCTAssertNil(s.signalingDeadline)
        XCTAssertEqual(s.handle(.tick, now: at(60)), [])
        XCTAssertEqual(s.state, .waiting)
    }

    func testUndecodableButAuthenticatedPayloadIsDropped() {
        var s = waiting()
        _ = s.handle(.peerJoined, now: base)
        _ = s.handle(.signalingReady, now: base)
        XCTAssertEqual(s.handle(.signal(Data("{\"k\":\"zzz\"}".utf8)), now: base), [])
        XCTAssertTrue(s.peerAuthenticated)
        XCTAssertEqual(s.state, .waiting)
    }

    func testThirdPartyJoinWhileConnectedDoesNotDisturb() {
        var s = secured()
        for e in [S.Event.peerJoined, .signalingReady, .signal(Data([1, 2, 3])), .peerLeft, .signalingClosed] {
            XCTAssertEqual(s.handle(e, now: at(1)), [])
        }
        XCTAssertTrue(s.isSecured)
    }

    func testPeerLeftKeepsSocketAndAwaitsJoined() {
        var s = waitingAuthenticatedAnswerer()
        XCTAssertEqual(s.handle(.peerLeft, now: at(1)), [])
        XCTAssertEqual(s.state, .waiting)
        XCTAssertTrue(s.socketOpen)
        XCTAssertFalse(s.peerAuthenticated)
        // A later joined begins a fresh 5 s window.
        _ = s.handle(.peerJoined, now: at(10))
        XCTAssertEqual(s.handle(.tick, now: at(14.9)), [])
        XCTAssertEqual(s.handle(.tick, now: at(15)), [.leaveRoom, .scheduleRetry(at: at(16))])
    }

    func testMultipleJoinedDuringNegotiationRestartsCleanly() {
        var s = negotiating()
        XCTAssertEqual(s.handle(.peerJoined, now: at(2)), [.closeConnection])
        _ = s.handle(.signalingReady, now: at(2))
        XCTAssertEqual(s.handle(.signal(ready), now: at(2)), [.startNegotiation(.offerer, attempt: 2)])
    }

    // MARK: - Roles

    func testRoleIsSmallerKeyOffers() throws {
        let small = Data([0x01] + Array(repeating: 0, count: 31))
        let large = Data([0x02] + Array(repeating: 0, count: 31))
        XCTAssertEqual(try RendezvousRole.forKeys(myKey: small, peerKey: large), .offerer)
        XCTAssertEqual(try RendezvousRole.forKeys(myKey: large, peerKey: small), .answerer)
        XCTAssertThrowsError(try RendezvousRole.forKeys(myKey: small, peerKey: small))
    }

    func testAnswererStartsOnlyOnOfferAndDropsWrongRolePayloads() {
        var s = waitingAuthenticatedAnswerer()
        XCTAssertEqual(s.handle(.signal(RendezvousSignal.answer(sdp: "x").encoded()), now: at(1)), [])
        let offer = RendezvousSignal.offer(sdp: "v=0")
        XCTAssertEqual(s.handle(.signal(offer.encoded()), now: at(1)),
                       [.startNegotiation(.answerer, attempt: 1), .deliverRemoteSignal(offer, attempt: 1)])
        XCTAssertEqual(s.state, .negotiating)
        // A second offer in the same session is dropped; ICE flows; our answer goes out.
        XCTAssertEqual(s.handle(.signal(offer.encoded()), now: at(1)), [])
        let ice = RendezvousSignal.ice(sdp: "candidate:1", mid: "0", index: 0)
        XCTAssertEqual(s.handle(.signal(ice.encoded()), now: at(1)), [.deliverRemoteSignal(ice, attempt: 1)])
        XCTAssertEqual(s.handle(.localSignal(.offer(sdp: "no")), now: at(1)), [])
        let ans = RendezvousSignal.answer(sdp: "a")
        XCTAssertEqual(s.handle(.localSignal(ans), now: at(1)), [.sendSignal(ans.encoded())])
    }

    func testOffererDropsOffersAndSendsOwnOffer() {
        var s = negotiating()
        XCTAssertEqual(s.handle(.signal(RendezvousSignal.offer(sdp: "evil").encoded()), now: at(1)), [])
        let offer = RendezvousSignal.offer(sdp: "mine")
        XCTAssertEqual(s.handle(.localSignal(offer), now: at(1)), [.sendSignal(offer.encoded())])
        let ans = RendezvousSignal.answer(sdp: "theirs")
        XCTAssertEqual(s.handle(.signal(ans.encoded()), now: at(1)), [.deliverRemoteSignal(ans, attempt: 1)])
    }

    func testLocalIceAfterOpenIsNotSent() {
        var s = connected()
        XCTAssertEqual(s.handle(.localSignal(.ice(sdp: "c", mid: nil, index: 0)), now: at(1)), [])
    }

    // MARK: - Timeouts (exact boundaries)

    func testNegotiationTimeoutThirtySeconds() {
        var s = negotiating()
        XCTAssertEqual(s.handle(.tick, now: at(29.999)), [])
        XCTAssertEqual(s.handle(.tick, now: at(30)), [.closeConnection, .leaveRoom, .scheduleRetry(at: at(31))])
        XCTAssertEqual(s.state, .failed(.negotiationTimeout))
    }

    func testSecureChannelTimeoutFiveSecondsNoPlaintextFallback() {
        var s = connected()
        XCTAssertEqual(s.handle(.tick, now: at(4.999)), [])
        XCTAssertEqual(s.handle(.tick, now: at(5)), [.closeConnection, .leaveRoom, .scheduleRetry(at: at(6))])
        XCTAssertEqual(s.state, .failed(.secureChannelTimeout))
        // A late success cannot resurrect it.
        XCTAssertEqual(s.handle(.secureChannelResult(ok: true), now: at(5.1)), [])
        XCTAssertFalse(s.isSecured)
    }

    func testInstallRejectedFailsWithBackoff() {
        var s = connected()
        XCTAssertEqual(s.handle(.installFailed, now: at(1)), [.closeConnection, .leaveRoom, .scheduleRetry(at: at(2))])
        XCTAssertEqual(s.state, .failed(.installRejected))
    }

    func testNegotiationFailure() {
        var s = negotiating()
        XCTAssertEqual(s.handle(.negotiationFailed, now: at(1)), [.closeConnection, .leaveRoom, .scheduleRetry(at: at(2))])
    }

    func testSignalingClosedWhileNegotiatingClosesConnectionWithoutLeave() {
        var s = negotiating()
        XCTAssertEqual(s.handle(.signalingClosed, now: at(1)), [.closeConnection, .scheduleRetry(at: at(2))])
    }

    // MARK: - Backoff

    func testBackoffScheduleCapsAtFiveMinutesPlusJitter() {
        let expected: [TimeInterval] = [1, 2, 4, 8, 16, 32, 64, 128, 256, 300, 300, 300]
        XCTAssertEqual((1...12).map { S.backoffDelay(failures: $0, jitter: 0) }, expected)
        XCTAssertEqual(S.backoffDelay(failures: 3, jitter: 12.5), 16.5)
        XCTAssertEqual(S.backoffDelay(failures: 50, jitter: 30), 330)
        XCTAssertEqual(S.backoffDelay(failures: 1, jitter: 45), 31, "jitter clamped to 30")
        XCTAssertEqual(S.backoffDelay(failures: 1, jitter: -2), 1)
        XCTAssertEqual(S.backoffDelay(failures: 1, jitter: .nan), 1)
    }

    func testRepeatedFailuresFollowScheduleWithInjectedJitter() {
        var s = waiting()
        var now = base
        var delays: [TimeInterval] = []
        for _ in 0..<5 {
            let a = s.handle(.signalingClosed, now: now, context: .init(jitter: 7))
            guard case .scheduleRetry(let at)? = a.last else { return XCTFail("\(a)") }
            delays.append(at.timeIntervalSince(now))
            XCTAssertEqual(s.handle(.tick, now: at.addingTimeInterval(-0.001)), [])
            XCTAssertEqual(s.handle(.tick, now: at), [.joinRoom(token: token)])
            now = at
        }
        XCTAssertEqual(delays, [8, 9, 11, 15, 23])
    }

    func testSecuredConnectionResetsBackoff() {
        var s = waiting()
        _ = s.handle(.signalingClosed, now: base)
        _ = s.handle(.tick, now: at(1))
        _ = s.handle(.signalingClosed, now: at(1))
        XCTAssertEqual(s.consecutiveFailures, 2)
        _ = s.handle(.tick, now: at(3))
        _ = s.handle(.peerJoined, now: at(3))
        _ = s.handle(.signalingReady, now: at(3))
        _ = s.handle(.signal(ready), now: at(3))
        _ = s.handle(.dataChannelOpen, now: at(3))
        _ = s.handle(.secureChannelResult(ok: true), now: at(3))
        XCTAssertEqual(s.consecutiveFailures, 0)
        XCTAssertEqual(s.handle(.connectionLost, now: at(100)), [.closeConnection, .scheduleRetry(at: at(101))])
        XCTAssertEqual(s.state, .failed(.connectionLost))
    }

    /// Ruling R-a: the FIRST join after foreground/enable is immediate; jitter
    /// applies to retries only.
    func testFirstJoinIsImmediateJitterOnlyOnRetries() {
        var s = S(contactID: contact, day: 1, token: token, role: .offerer, isForeground: false, isEnabled: true)
        XCTAssertEqual(s.handle(.appForeground, now: base, context: .init(jitter: 12)), [.joinRoom(token: token)])
        XCTAssertEqual(s.state, .waiting)
        XCTAssertEqual(s.handle(.signalingClosed, now: at(1), context: .init(jitter: 12)), [.scheduleRetry(at: at(1 + 1 + 12))])
        var e = S(contactID: contact, day: 1, token: token, role: .offerer, isForeground: true, isEnabled: false)
        XCTAssertEqual(e.handle(.enabled, now: base, context: .init(jitter: 30)), [.joinRoom(token: token)])
    }

    // MARK: - Ruling R-b: healthy socket resets backoff

    /// Three quick failures, then a socket that completes a handshake at 7 s
    /// and stays up. Exactly 60 s healthy does not reset (failure 4 ⇒ 8 s);
    /// more than 60 s resets (failure 1 ⇒ 1 s).
    func testSocketHealthyOverSixtySecondsResetsBackoff() {
        var s = waiting()                          // joined at 0
        _ = s.handle(.signalingClosed, now: base)  // f1, retry at 1
        _ = s.handle(.tick, now: at(1))
        _ = s.handle(.signalingClosed, now: at(1)) // f2, retry at 3
        _ = s.handle(.tick, now: at(3))
        _ = s.handle(.signalingClosed, now: at(3)) // f3, retry at 7
        XCTAssertEqual(s.handle(.tick, now: at(7)), [.joinRoom(token: token)])
        _ = s.handle(.peerJoined, now: at(7))
        _ = s.handle(.signalingReady, now: at(7))  // healthy clock starts here
        var exactly = s
        XCTAssertEqual(exactly.handle(.signalingClosed, now: at(67)), [.scheduleRetry(at: at(75))])
        XCTAssertEqual(exactly.consecutiveFailures, 4)
        XCTAssertEqual(s.handle(.signalingClosed, now: at(68)), [.scheduleRetry(at: at(69))])
        XCTAssertEqual(s.consecutiveFailures, 1)
    }

    func testHealthySocketResetAlsoAppliesToSignalingTimeout() {
        var s = waiting()
        _ = s.handle(.signalingClosed, now: base)
        _ = s.handle(.tick, now: at(1))
        _ = s.handle(.signalingClosed, now: at(1))
        _ = s.handle(.tick, now: at(3))            // joined at 3, failures 2
        _ = s.handle(.peerJoined, now: at(3))
        _ = s.handle(.signalingReady, now: at(3))  // healthy since 3
        _ = s.handle(.peerLeft, now: at(4))        // socket stays up
        _ = s.handle(.peerJoined, now: at(100))
        XCTAssertEqual(s.handle(.tick, now: at(105)), [.leaveRoom, .scheduleRetry(at: at(106))])
    }

    /// Round 2 (d): a connect that hangs (no handshake ever) against an
    /// unreachable Worker is not "healthy" — backoff keeps growing to the cap.
    func testHangingConnectDoesNotResetBackoff() {
        var s = waiting()
        var now = base
        for _ in 0..<12 {
            now = now.addingTimeInterval(500)  // socket "open" for 500 s, never handshakes
            let a = s.handle(.signalingClosed, now: now)
            guard case .scheduleRetry(let at)? = a.last else { return XCTFail("\(a)") }
            now = at
            XCTAssertEqual(s.handle(.tick, now: now), [.joinRoom(token: token)])
        }
        XCTAssertEqual(s.consecutiveFailures, 12)
        let a = s.handle(.signalingClosed, now: now.addingTimeInterval(500))
        XCTAssertEqual(a, [.scheduleRetry(at: now.addingTimeInterval(500 + 300))])
    }

    /// Round 2 (b): the installer reported OK synchronously, then refused.
    func testInstallFailedAfterSecuredStillFails() {
        var s = secured()
        XCTAssertEqual(s.handle(.installFailed, now: at(1)), [.closeConnection, .scheduleRetry(at: at(2))])
        XCTAssertEqual(s.state, .failed(.installRejected))
    }

    // MARK: - Minor 11: remote ICE cap

    func testRemoteICECappedPerAttempt() {
        var s = negotiating()
        let ice = RendezvousSignal.ice(sdp: "c", mid: nil, index: 0)
        for _ in 0..<S.maxRemoteICECandidates {
            XCTAssertEqual(s.handle(.signal(ice.encoded()), now: base), [.deliverRemoteSignal(ice, attempt: 1)])
        }
        XCTAssertEqual(s.handle(.signal(ice.encoded()), now: base), [])
        let ans = RendezvousSignal.answer(sdp: "a")
        XCTAssertEqual(s.handle(.signal(ans.encoded()), now: base), [.deliverRemoteSignal(ans, attempt: 1)])
        XCTAssertEqual(S.maxRemoteICECandidates, 64)
    }

    func testNotEnabledNeverJoins() {
        var s = S(contactID: contact, day: 1, token: token, role: .offerer)
        XCTAssertEqual(s.handle(.appForeground, now: base), [])
        XCTAssertEqual(s.handle(.tick, now: at(1000)), [])
        XCTAssertEqual(s.state, .idle)
    }

    func testBackgroundThenForegroundRejoins() {
        var s = secured()
        XCTAssertEqual(s.handle(.appBackground, now: at(1)), [.closeConnection])
        XCTAssertEqual(s.handle(.appForeground, now: at(2)), [.joinRoom(token: token)])
        XCTAssertEqual(s.state, .waiting)
    }

    // MARK: - Sibling discipline (day boundary)

    func testOffererParksWhileSiblingBusyAndStartsWhenFree() {
        var s = waiting()
        _ = s.handle(.peerJoined, now: base)
        _ = s.handle(.signalingReady, now: base)
        XCTAssertEqual(s.handle(.signal(ready), now: base, context: .init(siblingBusy: true)), [])
        XCTAssertTrue(s.parked)
        XCTAssertEqual(s.handle(.negotiationSlotFree, now: at(1), context: .init(siblingBusy: true)), [])
        XCTAssertEqual(s.handle(.negotiationSlotFree, now: at(1)), [.startNegotiation(.offerer, attempt: 1)])
    }

    func testSiblingNegotiatingSupersedesAnswerer() {
        var s = waitingAuthenticatedAnswerer()
        _ = s.handle(.signal(RendezvousSignal.offer(sdp: "o").encoded()), now: base)
        XCTAssertEqual(s.handle(.siblingNegotiating, now: at(1)), [.closeConnection])
        XCTAssertEqual(s.state, .waiting)
        XCTAssertTrue(s.socketOpen)
    }

    func testRetireClosesWithoutFrames() {
        var s = negotiating()
        XCTAssertEqual(s.handle(.retire, now: at(1)), [.closeConnection, .leaveRoom])
        XCTAssertEqual(s.state, .closed)
    }

    // MARK: - Signal codec

    func testSignalCodecRoundTripAndLimits() {
        let all: [RendezvousSignal] = [.ready, .offer(sdp: "o"), .answer(sdp: "a"), .ice(sdp: "c", mid: nil, index: 3),
                                       .ice(sdp: "c", mid: "0", index: 0)]
        for s in all { XCTAssertEqual(RendezvousSignal.decode(s.encoded()), s) }
        XCTAssertNil(RendezvousSignal.decode(Data("not json".utf8)))
        XCTAssertNil(RendezvousSignal.decode(Data("{\"k\":\"offer\"}".utf8)))
        let huge = String(repeating: "x", count: RendezvousSignal.maxSDPBytes + 1)
        XCTAssertNil(RendezvousSignal.decode(RendezvousSignal.offer(sdp: huge).encoded()))
    }
}
