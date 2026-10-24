import XCTest
import CryptoKit
@testable import PeerDropCore
import PeerDropProtocol

final class NotesExchangeSessionTests: XCTestCase {

    typealias S = NotesExchangeSession

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func n(_ b: UInt8) -> Data { Data(repeating: b, count: 32) }

    private let mySigning = Curve25519.Signing.PrivateKey()
    private var myAccount: S.AccountSnapshot {
        S.AccountSnapshot(accountId: "MYAC0001", signingKey: mySigning.publicKey.rawRepresentation)!
    }
    private let peerSigning = Curve25519.Signing.PrivateKey()

    /// A structurally valid reveal from the peer (signature not checked by the session).
    private func peerReveal(accountId: String = "PEER0001") -> NotesExchangePayload {
        NotesExchangePayload(phase: "reveal", accountId: accountId,
                             signingKey: peerSigning.publicKey.rawRepresentation,
                             signature: Data(repeating: 7, count: 64))
    }

    private func readySession() -> S {
        var s = S()
        XCTAssertEqual(s.handle(.localAccountReady(myAccount, now: t0)), [])
        return s
    }

    private func reveals(_ actions: [S.Action]) -> Int {
        actions.filter { if case .sendReveal = $0 { return true } else { return false } }.count
    }

    // MARK: - Ticks (fix round 1, M7)

    func testNeedsTicksOnlyWhileWorkIsOwed() {
        var s = S()
        XCTAssertFalse(s.needsTicks)
        _ = s.handle(.userPressed(nonce: n(1), now: t0))
        XCTAssertTrue(s.needsTicks, "my intent can expire")
        _ = s.handle(.receivedIntent(nonce: n(2), now: t0))     // account unknown: pair waits
        XCTAssertTrue(s.needsTicks)
        _ = s.handle(.receivedReveal(peerReveal(), now: t0))
        _ = s.handle(.verificationSucceeded)
        XCTAssertEqual(s.state, .bound)
        XCTAssertTrue(s.needsTicks, "bound but my response is still owed: expiry must withdraw it")
        _ = s.handle(.localAccountReady(myAccount, now: t0))     // reveal goes out
        XCTAssertFalse(s.needsTicks, "bound and nothing owed")

        var p = S()
        _ = p.handle(.receivedIntent(nonce: n(3), now: t0))
        XCTAssertTrue(p.needsTicks, "the peer's intent can expire")
        _ = p.handle(.disconnected)
        XCTAssertFalse(p.needsTicks)
    }

    // MARK: - Brief-listed tests

    func testBothPressSendsReveal() {
        var s = readySession()
        XCTAssertEqual(s.handle(.userPressed(nonce: n(1), now: t0)),
                       [.sendIntent(nonce: n(1)), .updateState(.waitingForPeer)])
        XCTAssertEqual(s.handle(.receivedIntent(nonce: n(2), now: t0)),
                       [.sendReveal(account: myAccount, nonces: NotesExchangePair(mine: n(1), theirs: n(2))),
                        .updateState(.exchanging)])
        XCTAssertEqual(s.state, .exchanging)
    }

    func testPeerPressesFirstThenIPress() {
        var s = readySession()
        XCTAssertEqual(s.handle(.receivedIntent(nonce: n(2), now: t0)), [.updateState(.peerWantsExchange)])
        XCTAssertEqual(s.handle(.userPressed(nonce: n(1), now: t0)),
                       [.sendIntent(nonce: n(1)),
                        .sendReveal(account: myAccount, nonces: NotesExchangePair(mine: n(1), theirs: n(2))),
                        .updateState(.exchanging)])
    }

    func testSimultaneousPressNoDuplicateReveal() {
        // Both sides press at once: each sends intent before seeing the other's.
        var s = readySession()
        var all: [S.Action] = []
        all += s.handle(.userPressed(nonce: n(1), now: t0))
        all += s.handle(.receivedIntent(nonce: n(2), now: t0))
        all += s.handle(.receivedReveal(peerReveal(), now: t0))
        // Peer re-sends its intent, user taps again, more intents arrive.
        all += s.handle(.receivedIntent(nonce: n(2), now: t0))
        all += s.handle(.userPressed(nonce: n(3), now: t0))
        all += s.handle(.receivedIntent(nonce: n(4), now: t0))
        XCTAssertEqual(reveals(all), 1)
        XCTAssertEqual(all.filter { if case .sendIntent = $0 { return true } else { return false } }.count, 1)
        XCTAssertTrue(all.contains(.verify(reveal: peerReveal(), nonces: NotesExchangePair(mine: n(1), theirs: n(2)))))
        XCTAssertEqual(s.state, .verifying)
    }

    func testRevealWithoutMyIntentIgnored() {
        var s = readySession()
        XCTAssertEqual(s.handle(.receivedReveal(peerReveal(), now: t0)), [])
        XCTAssertEqual(s.state, .idle)
        XCTAssertEqual(s.handle(.receivedIntent(nonce: n(2), now: t0)), [.updateState(.peerWantsExchange)])
        XCTAssertEqual(s.handle(.receivedReveal(peerReveal(), now: t0)), [], "unsolicited push while only the PEER pressed")
        XCTAssertEqual(s.state, .peerWantsExchange)
    }

    func testRevealWithOnlyMyIntentIgnoredAndDoesNotConsumeSlot() {
        // A reveal while only MY intent exists means the peer claims to have seen
        // both intents but we never received theirs: ignore without state change.
        var s = readySession()
        _ = s.handle(.userPressed(nonce: n(1), now: t0))
        XCTAssertEqual(s.handle(.receivedReveal(peerReveal(), now: t0)), [])
        XCTAssertEqual(s.state, .waitingForPeer)
        _ = s.handle(.receivedIntent(nonce: n(2), now: t0))
        XCTAssertEqual(s.handle(.receivedReveal(peerReveal(), now: t0)),
                       [.verify(reveal: peerReveal(), nonces: NotesExchangePair(mine: n(1), theirs: n(2))),
                        .updateState(.verifying)])
    }

    func testDuplicateIntentIgnored() {
        var s = readySession()
        _ = s.handle(.receivedIntent(nonce: n(2), now: t0))
        XCTAssertEqual(s.handle(.receivedIntent(nonce: n(3), now: t0)), [])
        XCTAssertEqual(s.handle(.receivedIntent(nonce: n(2), now: t0)), [])
        // The FIRST intent's nonce is the one bound into the exchange.
        XCTAssertEqual(s.handle(.userPressed(nonce: n(1), now: t0)),
                       [.sendIntent(nonce: n(1)),
                        .sendReveal(account: myAccount, nonces: NotesExchangePair(mine: n(1), theirs: n(2))),
                        .updateState(.exchanging)])
    }

    func testReplayedRevealAfterDisconnectIgnored() {
        var s = readySession()
        _ = s.handle(.userPressed(nonce: n(1), now: t0))
        _ = s.handle(.receivedIntent(nonce: n(2), now: t0))
        XCTAssertEqual(s.handle(.disconnected), [.updateState(.idle)])
        XCTAssertEqual(s.state, .idle)
        XCTAssertEqual(s.handle(.receivedReveal(peerReveal(), now: t0)), [])
        XCTAssertEqual(s.handle(.receivedIntent(nonce: n(2), now: t0)), [])
        XCTAssertEqual(s.handle(.userPressed(nonce: n(5), now: t0)), [])
        XCTAssertEqual(s.handle(.receivedUnavailable), [])
        XCTAssertEqual(s.handle(.verificationSucceeded), [])
        XCTAssertEqual(s.handle(.tick(now: t0 + 10_000)), [])
        XCTAssertEqual(s.handle(.disconnected), [])
        XCTAssertEqual(s.state, .idle)
    }

    func testIntentExpiresAfter600s() {
        var s = readySession()
        XCTAssertEqual(S.intentLifetime, 600)
        XCTAssertEqual(s.handle(.tick(now: t0)), [])
        _ = s.handle(.userPressed(nonce: n(1), now: t0))
        XCTAssertEqual(s.handle(.tick(now: t0 + 599.999)), [], "not yet at the boundary")
        XCTAssertEqual(s.state, .waitingForPeer)
        XCTAssertEqual(s.handle(.tick(now: t0 + 600)), [.sendCancel, .updateState(.expired)], "expires AT 600 s")
        XCTAssertEqual(s.handle(.tick(now: t0 + 700)), [])
        // A late peer intent no longer completes the exchange.
        XCTAssertEqual(s.handle(.receivedIntent(nonce: n(2), now: t0 + 700)), [.updateState(.peerWantsExchange)])
        // Pressing again starts a fresh intent with a fresh nonce.
        XCTAssertEqual(s.handle(.userPressed(nonce: n(3), now: t0 + 701)),
                       [.sendIntent(nonce: n(3)),
                        .sendReveal(account: myAccount, nonces: NotesExchangePair(mine: n(3), theirs: n(2))),
                        .updateState(.exchanging)])
    }

    func testPeerIntentExpiresSilently() {
        var s = readySession()
        _ = s.handle(.receivedIntent(nonce: n(2), now: t0))
        XCTAssertEqual(s.handle(.tick(now: t0 + 599)), [])
        XCTAssertEqual(s.handle(.tick(now: t0 + 600)), [.updateState(.idle)])
        XCTAssertEqual(s.handle(.userPressed(nonce: n(1), now: t0 + 601)),
                       [.sendIntent(nonce: n(1)), .updateState(.waitingForPeer)], "stale peer intent must not trigger a reveal")
    }

    func testNoExpiryOnceRevealSent() {
        var s = readySession()
        _ = s.handle(.userPressed(nonce: n(1), now: t0))
        _ = s.handle(.receivedIntent(nonce: n(2), now: t0))
        XCTAssertEqual(s.handle(.tick(now: t0 + 100_000)), [])
        XCTAssertEqual(s.state, .exchanging)
    }

    func testCancelClearsPeerIntentOnly() {
        var s = readySession()
        _ = s.handle(.receivedIntent(nonce: n(2), now: t0))
        XCTAssertEqual(s.handle(.receivedCancel), [.updateState(.idle)])
        XCTAssertEqual(s.handle(.userPressed(nonce: n(1), now: t0)),
                       [.sendIntent(nonce: n(1)), .updateState(.waitingForPeer)])
        // My intent survives a peer cancel.
        XCTAssertEqual(s.handle(.receivedCancel), [])
        XCTAssertEqual(s.state, .waitingForPeer)
        // A fresh peer intent after the cancel is accepted and completes the pair.
        XCTAssertEqual(reveals(s.handle(.receivedIntent(nonce: n(4), now: t0))), 1)
    }

    func testCancelAfterBoundDoesNotUnbind() {
        var s = readySession()
        _ = s.handle(.userPressed(nonce: n(1), now: t0))
        _ = s.handle(.receivedIntent(nonce: n(2), now: t0))
        _ = s.handle(.receivedReveal(peerReveal(), now: t0))
        XCTAssertEqual(s.handle(.verificationSucceeded), [.updateState(.bound)])
        XCTAssertEqual(s.handle(.receivedCancel), [])
        XCTAssertEqual(s.state, .bound)
        XCTAssertEqual(s.handle(.userCancelled), [])
        XCTAssertEqual(s.state, .bound)
    }

    func testCancelAfterMyRevealIgnored() {
        var s = readySession()
        _ = s.handle(.userPressed(nonce: n(1), now: t0))
        _ = s.handle(.receivedIntent(nonce: n(2), now: t0))
        XCTAssertEqual(s.handle(.receivedCancel), [])
        XCTAssertEqual(s.state, .exchanging)
        // Nonces stay frozen: the peer's reveal is still verified against n(2).
        XCTAssertEqual(s.handle(.receivedReveal(peerReveal(), now: t0)).first,
                       .verify(reveal: peerReveal(), nonces: NotesExchangePair(mine: n(1), theirs: n(2))))
    }

    func testLocalAccountUnavailableSendsUnavailable() {
        var s = S()
        XCTAssertEqual(s.handle(.localAccountReady(nil, now: t0)), [])
        _ = s.handle(.userPressed(nonce: n(1), now: t0))
        XCTAssertEqual(s.handle(.receivedIntent(nonce: n(2), now: t0)),
                       [.sendUnavailable, .updateState(.failed(.localAccountUnavailable))])
        XCTAssertEqual(s.handle(.receivedReveal(peerReveal(), now: t0)), [])
        XCTAssertEqual(s.handle(.localAccountReady(myAccount, now: t0)), [], "never reveal after saying unavailable")
        XCTAssertEqual(s.handle(.userPressed(nonce: n(3), now: t0)), [])
        XCTAssertEqual(s.state, .failed(.localAccountUnavailable))
    }

    func testAccountBecomesUnavailableBeforePairCompletes() {
        var s = readySession()
        _ = s.handle(.userPressed(nonce: n(1), now: t0))
        XCTAssertEqual(s.handle(.localAccountReady(nil, now: t0)), [])
        XCTAssertEqual(s.handle(.receivedIntent(nonce: n(2), now: t0)),
                       [.sendUnavailable, .updateState(.failed(.localAccountUnavailable))])
    }

    func testAccountUnknownWaitsThenReveals() {
        var s = S()
        _ = s.handle(.userPressed(nonce: n(1), now: t0))
        XCTAssertEqual(s.handle(.receivedIntent(nonce: n(2), now: t0)), [.updateState(.exchanging)])
        XCTAssertEqual(s.handle(.localAccountReady(myAccount, now: t0)),
                       [.sendReveal(account: myAccount, nonces: NotesExchangePair(mine: n(1), theirs: n(2)))])
        XCTAssertEqual(s.handle(.localAccountReady(myAccount, now: t0)), [], "at most one reveal")
    }

    func testRevealWhileWaitingForMyAccountIsAccepted() {
        var s = S()
        _ = s.handle(.userPressed(nonce: n(1), now: t0))
        _ = s.handle(.receivedIntent(nonce: n(2), now: t0))
        XCTAssertEqual(s.handle(.receivedReveal(peerReveal(), now: t0)),
                       [.verify(reveal: peerReveal(), nonces: NotesExchangePair(mine: n(1), theirs: n(2))),
                        .updateState(.verifying)])
        XCTAssertEqual(s.handle(.localAccountReady(myAccount, now: t0)),
                       [.sendReveal(account: myAccount, nonces: NotesExchangePair(mine: n(1), theirs: n(2)))])
        XCTAssertEqual(s.state, .verifying)
    }

    func testCancelWhileWaitingForMyAccountWithdrawsPair() {
        var s = S()
        _ = s.handle(.userPressed(nonce: n(1), now: t0))
        _ = s.handle(.receivedIntent(nonce: n(2), now: t0))
        XCTAssertEqual(s.handle(.receivedCancel), [.updateState(.waitingForPeer)])
        XCTAssertEqual(s.handle(.localAccountReady(myAccount, now: t0)), [], "peer withdrew before we revealed")
    }

    func testPeerUnavailableEndsExchange() {
        var s = readySession()
        _ = s.handle(.userPressed(nonce: n(1), now: t0))
        _ = s.handle(.receivedIntent(nonce: n(2), now: t0))
        XCTAssertEqual(s.handle(.receivedUnavailable), [.updateState(.peerUnavailable)])
        XCTAssertEqual(s.handle(.receivedReveal(peerReveal(), now: t0)), [])
        XCTAssertEqual(s.handle(.receivedUnavailable), [])
        XCTAssertEqual(s.handle(.userPressed(nonce: n(3), now: t0)), [])
        XCTAssertEqual(s.state, .peerUnavailable)
    }

    func testUnavailableBeforeIntentsIgnored() {
        var s = readySession()
        XCTAssertEqual(s.handle(.receivedUnavailable), [])
        _ = s.handle(.userPressed(nonce: n(1), now: t0))
        XCTAssertEqual(s.handle(.receivedUnavailable), [])
        XCTAssertEqual(s.state, .waitingForPeer)
        var p = readySession()
        _ = p.handle(.receivedIntent(nonce: n(2), now: t0))
        XCTAssertEqual(p.handle(.receivedUnavailable), [])
        XCTAssertEqual(p.state, .peerWantsExchange)
    }

    func testPeerUnavailableWhileWaitingForAccountSuppressesReveal() {
        var s = S()
        _ = s.handle(.userPressed(nonce: n(1), now: t0))
        _ = s.handle(.receivedIntent(nonce: n(2), now: t0))
        XCTAssertEqual(s.handle(.receivedUnavailable), [.updateState(.peerUnavailable)])
        XCTAssertEqual(s.handle(.localAccountReady(myAccount, now: t0)), [], "no reason to reveal to a peer without an account")
    }

    func testUnavailableAfterPeerRevealIgnored() {
        var s = readySession()
        _ = s.handle(.userPressed(nonce: n(1), now: t0))
        _ = s.handle(.receivedIntent(nonce: n(2), now: t0))
        _ = s.handle(.receivedReveal(peerReveal(), now: t0))
        XCTAssertEqual(s.handle(.receivedUnavailable), [])
        XCTAssertEqual(s.state, .verifying)
    }

    func testSecondRevealIgnored() {
        var s = readySession()
        _ = s.handle(.userPressed(nonce: n(1), now: t0))
        _ = s.handle(.receivedIntent(nonce: n(2), now: t0))
        XCTAssertEqual(s.handle(.receivedReveal(peerReveal(), now: t0)).count, 2)
        XCTAssertEqual(s.handle(.receivedReveal(peerReveal(accountId: "OTHER001"), now: t0)), [])
        XCTAssertEqual(s.handle(.verificationSucceeded), [.updateState(.bound)])
        XCTAssertEqual(s.handle(.receivedReveal(peerReveal(), now: t0)), [])
        XCTAssertEqual(s.state, .bound)
    }

    // MARK: - Extras

    func testVerificationFailed() {
        var s = readySession()
        _ = s.handle(.userPressed(nonce: n(1), now: t0))
        _ = s.handle(.receivedIntent(nonce: n(2), now: t0))
        _ = s.handle(.receivedReveal(peerReveal(), now: t0))
        XCTAssertEqual(s.handle(.verificationFailed), [.updateState(.failed(.verificationFailed))])
        XCTAssertEqual(s.handle(.verificationSucceeded), [])
        XCTAssertEqual(s.handle(.receivedReveal(peerReveal(), now: t0)), [])
        XCTAssertEqual(s.state, .failed(.verificationFailed))
    }

    func testVerificationResultWithoutPendingVerifyIgnored() {
        var s = readySession()
        XCTAssertEqual(s.handle(.verificationSucceeded), [])
        _ = s.handle(.userPressed(nonce: n(1), now: t0))
        _ = s.handle(.receivedIntent(nonce: n(2), now: t0))
        XCTAssertEqual(s.handle(.verificationSucceeded), [], "no reveal received yet")
        XCTAssertEqual(s.handle(.verificationFailed), [])
        XCTAssertEqual(s.state, .exchanging)
    }

    func testMalformedRevealFailsAndConsumesSlot() {
        for bad in [peerReveal(accountId: "peer0001"),
                    peerReveal(accountId: "PEER001"),
                    NotesExchangePayload(phase: "reveal", accountId: "PEER0001", signingKey: Data(repeating: 1, count: 31), signature: Data(repeating: 7, count: 64)),
                    NotesExchangePayload(phase: "reveal", accountId: "PEER0001", signingKey: peerSigning.publicKey.rawRepresentation, signature: Data(repeating: 7, count: 63)),
                    NotesExchangePayload(phase: "reveal", accountId: "PEER0001", signingKey: nil, signature: Data(repeating: 7, count: 64))] {
            var s = readySession()
            _ = s.handle(.userPressed(nonce: n(1), now: t0))
            _ = s.handle(.receivedIntent(nonce: n(2), now: t0))
            XCTAssertEqual(s.handle(.receivedReveal(bad, now: t0)), [.updateState(.failed(.invalidReveal))], "\(bad)")
            XCTAssertEqual(s.handle(.receivedReveal(peerReveal(), now: t0)), [])
        }
    }

    func testRevealWithWrongPhaseIgnored() {
        var s = readySession()
        _ = s.handle(.userPressed(nonce: n(1), now: t0))
        _ = s.handle(.receivedIntent(nonce: n(2), now: t0))
        var p = peerReveal(); p.phase = "intent"
        XCTAssertEqual(s.handle(.receivedReveal(p, now: t0)), [])
        XCTAssertEqual(s.handle(.receivedReveal(peerReveal(), now: t0)).count, 2)
    }

    func testReflectedRevealRejected() {
        // The peer echoes back OUR reveal: same digest by construction, so it must
        // be rejected by identity, not by signature.
        var s = readySession()
        _ = s.handle(.userPressed(nonce: n(1), now: t0))
        _ = s.handle(.receivedIntent(nonce: n(2), now: t0))
        let mine = NotesExchangePayload(phase: "reveal", accountId: myAccount.accountId,
                                        signingKey: myAccount.signingKey, signature: Data(repeating: 7, count: 64))
        XCTAssertEqual(s.handle(.receivedReveal(mine, now: t0)), [.updateState(.failed(.invalidReveal))])
        var s2 = readySession()
        _ = s2.handle(.userPressed(nonce: n(1), now: t0))
        _ = s2.handle(.receivedIntent(nonce: n(2), now: t0))
        let sameKey = NotesExchangePayload(phase: "reveal", accountId: "PEER0001",
                                           signingKey: myAccount.signingKey, signature: Data(repeating: 7, count: 64))
        XCTAssertEqual(s2.handle(.receivedReveal(sameKey, now: t0)), [.updateState(.failed(.invalidReveal))])
    }

    func testReflectedIntentNonceIgnored() {
        var s = readySession()
        _ = s.handle(.userPressed(nonce: n(1), now: t0))
        XCTAssertEqual(s.handle(.receivedIntent(nonce: n(1), now: t0)), [], "peer echoed our own nonce")
        XCTAssertEqual(s.state, .waitingForPeer)
    }

    func testWrongSizeNoncesIgnored() {
        var s = readySession()
        XCTAssertEqual(s.handle(.userPressed(nonce: Data(repeating: 1, count: 31), now: t0)), [])
        XCTAssertEqual(s.handle(.receivedIntent(nonce: Data(repeating: 2, count: 33), now: t0)), [])
        XCTAssertEqual(s.handle(.receivedIntent(nonce: Data(), now: t0)), [])
        XCTAssertEqual(s.state, .idle)
    }

    func testUserCancelWithdrawsMyIntent() {
        var s = readySession()
        XCTAssertEqual(s.handle(.userCancelled), [])
        _ = s.handle(.receivedIntent(nonce: n(2), now: t0 - 1))
        // Not possible to cancel what we never sent; peer intent stays.
        XCTAssertEqual(s.state, .peerWantsExchange)
        var w = readySession()
        _ = w.handle(.userPressed(nonce: n(1), now: t0))
        XCTAssertEqual(w.handle(.userCancelled), [.sendCancel, .updateState(.idle)])
        XCTAssertEqual(reveals(w.handle(.receivedIntent(nonce: n(2), now: t0))), 0)
        XCTAssertEqual(w.state, .peerWantsExchange)
    }

    func testPressAfterBoundIgnored() {
        var s = readySession()
        _ = s.handle(.userPressed(nonce: n(1), now: t0))
        _ = s.handle(.receivedIntent(nonce: n(2), now: t0))
        _ = s.handle(.receivedReveal(peerReveal(), now: t0))
        _ = s.handle(.verificationSucceeded)
        XCTAssertEqual(s.handle(.userPressed(nonce: n(9), now: t0)), [])
        XCTAssertEqual(s.handle(.receivedIntent(nonce: n(8), now: t0)), [])
    }

    // MARK: - Review fix round 1

    func testMyIntentExpiresOnIntentEventWithoutTick() {
        // Expiry must be enforced by every now-bearing event, not only `.tick`.
        var s = readySession()
        _ = s.handle(.userPressed(nonce: n(1), now: t0))
        let out = s.handle(.receivedIntent(nonce: n(2), now: t0 + 601))
        XCTAssertEqual(reveals(out), 0, "a late peer intent must not pair with my expired intent")
        XCTAssertTrue(out.contains(.sendCancel))
        // Same outcome as if a tick had fired first (behaviour must not depend on tick timing).
        var t = readySession()
        _ = t.handle(.userPressed(nonce: n(1), now: t0))
        _ = t.handle(.tick(now: t0 + 601))
        _ = t.handle(.receivedIntent(nonce: n(2), now: t0 + 601))
        XCTAssertEqual(s.state, t.state)
        XCTAssertEqual(s.state, .peerWantsExchange)
    }

    func testMyIntentExpiresOnIntentEventStateExpiredWhenPeerIntentInvalid() {
        // With no new peer intent recorded, the observable state is `.expired`.
        var s = readySession()
        _ = s.handle(.userPressed(nonce: n(1), now: t0))
        XCTAssertEqual(s.handle(.receivedIntent(nonce: n(1), now: t0 + 601)),
                       [.sendCancel, .updateState(.expired)], "reflected nonce ignored, but expiry still runs")
    }

    func testPeerIntentExpiresOnPressWithoutTick() {
        var s = readySession()
        _ = s.handle(.receivedIntent(nonce: n(2), now: t0))
        XCTAssertEqual(s.handle(.userPressed(nonce: n(1), now: t0 + 600)),
                       [.sendIntent(nonce: n(1)), .updateState(.waitingForPeer)])
    }

    func testBackwardsClockDoesNotExtendLifetime() {
        var s = readySession()
        _ = s.handle(.userPressed(nonce: n(1), now: t0))
        XCTAssertEqual(s.handle(.tick(now: t0 + 599)), [])
        XCTAssertEqual(s.handle(.tick(now: t0 - 5_000)), [], "a backwards jump is not an expiry")
        XCTAssertEqual(s.handle(.tick(now: t0 + 600)), [.sendCancel, .updateState(.expired)])

        // An intent made while the clock reads earlier than the latest time seen is
        // measured against that latest time: it can only expire sooner, never later.
        var b = readySession()
        _ = b.handle(.tick(now: t0 + 1_000))
        _ = b.handle(.userPressed(nonce: n(1), now: t0))
        XCTAssertEqual(b.handle(.tick(now: t0 + 50)), [.sendCancel, .updateState(.expired)])
    }

    func testMyRevealStillSentWhenPeerBoundFirst() {
        var s = S()
        _ = s.handle(.userPressed(nonce: n(1), now: t0))
        _ = s.handle(.receivedIntent(nonce: n(2), now: t0))
        _ = s.handle(.receivedReveal(peerReveal(), now: t0))
        XCTAssertEqual(s.handle(.verificationSucceeded), [.updateState(.bound)])
        let out = s.handle(.localAccountReady(myAccount, now: t0))
        XCTAssertEqual(out, [.sendReveal(account: myAccount, nonces: NotesExchangePair(mine: n(1), theirs: n(2)))])
        XCTAssertEqual(reveals(s.handle(.localAccountReady(myAccount, now: t0))), 0, "exactly one reveal")
        XCTAssertEqual(s.state, .bound)
    }

    func testLocalRevealFailedSendsUnavailableAndFails() {
        var s = readySession()
        _ = s.handle(.userPressed(nonce: n(1), now: t0))
        _ = s.handle(.receivedIntent(nonce: n(2), now: t0))
        XCTAssertEqual(s.state, .exchanging)
        XCTAssertEqual(s.handle(.localRevealFailed),
                       [.sendUnavailable, .updateState(.failed(.localRevealFailed))])
        XCTAssertEqual(s.handle(.localRevealFailed), [], "reported once")
        XCTAssertEqual(s.handle(.receivedReveal(peerReveal(), now: t0)), [])
        XCTAssertEqual(s.state, .failed(.localRevealFailed))
    }

    func testLocalRevealFailedWithoutSentRevealIgnored() {
        var s = readySession()
        XCTAssertEqual(s.handle(.localRevealFailed), [])
        _ = s.handle(.userPressed(nonce: n(1), now: t0))
        XCTAssertEqual(s.handle(.localRevealFailed), [])
        XCTAssertEqual(s.state, .waitingForPeer)
        var u = S()
        _ = u.handle(.localAccountReady(nil, now: t0))
        _ = u.handle(.userPressed(nonce: n(1), now: t0))
        _ = u.handle(.receivedIntent(nonce: n(2), now: t0))
        XCTAssertEqual(u.handle(.localRevealFailed), [], "we sent unavailable, not a reveal")
    }

    func testLocalRevealFailedKeepsPendingVerification() {
        var s = S()
        _ = s.handle(.userPressed(nonce: n(1), now: t0))
        _ = s.handle(.receivedIntent(nonce: n(2), now: t0))
        _ = s.handle(.receivedReveal(peerReveal(), now: t0))
        _ = s.handle(.localAccountReady(myAccount, now: t0))
        XCTAssertEqual(s.handle(.localRevealFailed), [.sendUnavailable])
        XCTAssertEqual(s.state, .verifying)
        XCTAssertEqual(s.handle(.verificationSucceeded), [.updateState(.bound)])
    }

    func testAccountUnavailableAfterPeerRevealKeepsPendingVerification() {
        var s = S()
        _ = s.handle(.userPressed(nonce: n(1), now: t0))
        _ = s.handle(.receivedIntent(nonce: n(2), now: t0))
        _ = s.handle(.receivedReveal(peerReveal(), now: t0))
        XCTAssertEqual(s.state, .verifying)
        XCTAssertEqual(s.handle(.localAccountReady(nil, now: t0)), [.sendUnavailable], "tell the peer, keep verifying")
        XCTAssertEqual(s.state, .verifying)
        XCTAssertEqual(s.handle(.localAccountReady(myAccount, now: t0)), [], "never reveal after unavailable")
        XCTAssertEqual(s.handle(.verificationFailed), [.updateState(.failed(.verificationFailed))])
        var b = S()
        _ = b.handle(.userPressed(nonce: n(1), now: t0))
        _ = b.handle(.receivedIntent(nonce: n(2), now: t0))
        _ = b.handle(.receivedReveal(peerReveal(), now: t0))
        _ = b.handle(.verificationSucceeded)
        XCTAssertEqual(b.handle(.localAccountReady(nil, now: t0)), [.sendUnavailable])
        XCTAssertEqual(b.state, .bound, "unavailable never overwrites a binding")
    }

    func testDeclinePeerIntent() {
        var s = readySession()
        _ = s.handle(.receivedIntent(nonce: n(2), now: t0))
        XCTAssertEqual(s.handle(.userCancelled), [.updateState(.idle)], "decline: no network action")
        XCTAssertEqual(s.handle(.receivedIntent(nonce: n(2), now: t0 + 1)), [], "same nonce does not re-prompt")
        // Even after the declined intent expires, a re-sent copy stays declined.
        _ = s.handle(.tick(now: t0 + 700))
        XCTAssertEqual(s.handle(.receivedIntent(nonce: n(2), now: t0 + 701)), [])
        XCTAssertEqual(s.state, .idle)
        // A fresh peer intent (new nonce) prompts again.
        XCTAssertEqual(s.handle(.receivedIntent(nonce: n(5), now: t0 + 702)), [.updateState(.peerWantsExchange)])
    }

    func testPressAfterDeclineStillPairs() {
        var s = readySession()
        _ = s.handle(.receivedIntent(nonce: n(2), now: t0))
        _ = s.handle(.userCancelled)
        XCTAssertEqual(s.handle(.userPressed(nonce: n(1), now: t0 + 1)),
                       [.sendIntent(nonce: n(1)),
                        .sendReveal(account: myAccount, nonces: NotesExchangePair(mine: n(1), theirs: n(2))),
                        .updateState(.exchanging)])
    }

    // MARK: - Review fix round 2 (consent after the pair is locked)

    /// Account unknown, both intents, peer reveal accepted (pair locked).
    private func lockedAwaitingAccount() -> S {
        var s = S()
        _ = s.handle(.userPressed(nonce: n(1), now: t0))
        _ = s.handle(.receivedIntent(nonce: n(2), now: t0))
        _ = s.handle(.receivedReveal(peerReveal(), now: t0))
        XCTAssertEqual(s.state, .verifying)
        return s
    }

    func testCancelAfterPeerRevealWithdrawsMyResponseForGood() {
        var s = lockedAwaitingAccount()
        XCTAssertEqual(s.handle(.userCancelled), [.sendUnavailable], "withdraw consent; peer is told")
        XCTAssertEqual(reveals(s.handle(.localAccountReady(myAccount, now: t0 + 1))), 0)
        XCTAssertEqual(s.handle(.userCancelled), [], "withdrawn once")
        XCTAssertEqual(s.state, .verifying, "pending verification is left to the CM")
        XCTAssertEqual(s.handle(.verificationSucceeded), [.updateState(.bound)])
        XCTAssertEqual(reveals(s.handle(.localAccountReady(myAccount, now: t0 + 2))), 0)
    }

    func testCancelAfterBoundWithdrawsMyResponse() {
        var s = lockedAwaitingAccount()
        _ = s.handle(.verificationSucceeded)
        XCTAssertEqual(s.handle(.userCancelled), [.sendUnavailable])
        XCTAssertEqual(reveals(s.handle(.localAccountReady(myAccount, now: t0 + 1))), 0)
        XCTAssertEqual(s.state, .bound)
    }

    func testCancelAfterMyRevealSentIsIgnored() {
        var s = readySession()
        _ = s.handle(.userPressed(nonce: n(1), now: t0))
        _ = s.handle(.receivedIntent(nonce: n(2), now: t0))
        XCTAssertEqual(s.handle(.userCancelled), [], "nothing left to withdraw")
    }

    func testLateAccountReadyAfterExpiryDoesNotReveal() {
        var s = S()
        _ = s.handle(.userPressed(nonce: n(1), now: t0))
        _ = s.handle(.receivedIntent(nonce: n(2), now: t0))
        let out = s.handle(.localAccountReady(myAccount, now: t0 + 601))
        XCTAssertEqual(reveals(out), 0)
        XCTAssertTrue(out.contains(.sendCancel))
        XCTAssertEqual(s.state, .expired)
    }

    func testLateAccountReadyAfterExpiryWhileLockedDoesNotReveal() {
        var s = lockedAwaitingAccount()
        XCTAssertEqual(s.handle(.localAccountReady(myAccount, now: t0 + 601)), [.sendUnavailable])
        XCTAssertEqual(s.state, .verifying)
        XCTAssertEqual(reveals(s.handle(.localAccountReady(myAccount, now: t0 + 602))), 0)
    }

    func testTickAfterExpiryWhileLockedWithdrawsOnce() {
        var s = lockedAwaitingAccount()
        XCTAssertEqual(s.handle(.tick(now: t0 + 599)), [])
        XCTAssertEqual(s.handle(.tick(now: t0 + 600)), [.sendUnavailable])
        XCTAssertEqual(s.handle(.tick(now: t0 + 700)), [])
        XCTAssertEqual(reveals(s.handle(.localAccountReady(myAccount, now: t0 + 701))), 0)
    }

    func testRevealAfterExpiryIsIgnored() {
        // The reveal's `now` runs expiry first, so it cannot lock an expired pair;
        // a later account-ready with an earlier clock reading changes nothing.
        var s = S()
        _ = s.handle(.userPressed(nonce: n(1), now: t0))
        _ = s.handle(.receivedIntent(nonce: n(2), now: t0))
        XCTAssertEqual(s.handle(.receivedReveal(peerReveal(), now: t0 + 601)),
                       [.sendCancel, .updateState(.expired)])
        XCTAssertEqual(reveals(s.handle(.localAccountReady(myAccount, now: t0))), 0)
        XCTAssertEqual(s.state, .expired)
    }

    func testIntentStaleOnArrivalNeverReveals() {
        // Backwards clock: my intent is already ≥ lifetime old against latestNow.
        var s = readySession()
        _ = s.handle(.tick(now: t0 + 1_000))
        _ = s.handle(.receivedIntent(nonce: n(2), now: t0 + 1_000))
        XCTAssertEqual(reveals(s.handle(.userPressed(nonce: n(1), now: t0))), 0)
        XCTAssertEqual(s.handle(.tick(now: t0 + 1_001)), [.sendCancel, .updateState(.peerWantsExchange)])
    }

    func testAccountReadyWithinLifetimeRevealsExactlyOnce() {
        var s = S()
        _ = s.handle(.userPressed(nonce: n(1), now: t0))
        _ = s.handle(.receivedIntent(nonce: n(2), now: t0))
        XCTAssertEqual(s.handle(.localAccountReady(myAccount, now: t0 + 599)),
                       [.sendReveal(account: myAccount, nonces: NotesExchangePair(mine: n(1), theirs: n(2)))])
        XCTAssertEqual(reveals(s.handle(.localAccountReady(myAccount, now: t0 + 599))), 0)
        var l = lockedAwaitingAccount()
        XCTAssertEqual(reveals(l.handle(.localAccountReady(myAccount, now: t0 + 599))), 1)
        XCTAssertEqual(reveals(l.handle(.tick(now: t0 + 700))), 0)
    }

    // MARK: - With real crypto

    func testReplayFromFreshSessionFailsVerification() throws {
        let myKey = Data(repeating: 0x10, count: 32), peerKey = Data(repeating: 0x90, count: 32)
        let peerAccount = S.AccountSnapshot(accountId: "PEER0001", signingKey: peerSigning.publicKey.rawRepresentation)!
        func peerSigns(_ nonces: NotesExchangePair) throws -> NotesExchangePayload {
            try NotesExchangeCrypto.makeReveal(account: peerAccount,
                                               handshakeKeys: NotesExchangePair(mine: peerKey, theirs: myKey),
                                               nonces: nonces, signer: { try self.peerSigning.signature(for: $0) })
        }
        func verifyAction(_ actions: [S.Action]) -> Bool? {
            for a in actions { if case let .verify(p, nonces) = a {
                return NotesExchangeCrypto.verifyReveal(payload: p, handshakeKeys: NotesExchangePair(mine: myKey, theirs: peerKey), nonces: nonces)
            } }
            return nil
        }

        // Connection 1: honest exchange verifies.
        var s1 = readySession()
        _ = s1.handle(.userPressed(nonce: n(1), now: t0))
        _ = s1.handle(.receivedIntent(nonce: n(2), now: t0))
        let captured = try peerSigns(NotesExchangePair(mine: n(2), theirs: n(1)))
        XCTAssertEqual(verifyAction(s1.handle(.receivedReveal(captured, now: t0))), true)
        _ = s1.handle(.disconnected)

        // Connection 2: attacker replays the old intent AND reveal; we pressed with a fresh nonce.
        var s2 = readySession()
        _ = s2.handle(.userPressed(nonce: n(3), now: t0))
        _ = s2.handle(.receivedIntent(nonce: n(2), now: t0))
        XCTAssertEqual(verifyAction(s2.handle(.receivedReveal(captured, now: t0))), false)
    }

    func testTwoSessionsAgreeEndToEnd() throws {
        // Two honest sessions wired back to back produce reveals that verify on both sides.
        let aKey = Data(repeating: 0xA0, count: 32), bKey = Data(repeating: 0x0B, count: 32)
        let aSign = Curve25519.Signing.PrivateKey(), bSign = Curve25519.Signing.PrivateKey()
        let aAcct = S.AccountSnapshot(accountId: "AAAA0001", signingKey: aSign.publicKey.rawRepresentation)!
        let bAcct = S.AccountSnapshot(accountId: "BBBB0001", signingKey: bSign.publicKey.rawRepresentation)!
        var a = S(), b = S()
        _ = a.handle(.localAccountReady(aAcct, now: t0)); _ = b.handle(.localAccountReady(bAcct, now: t0))
        let aOut = a.handle(.userPressed(nonce: n(0xA1), now: t0))
        let bOut = b.handle(.userPressed(nonce: n(0xB1), now: t0))
        guard case let .sendIntent(aNonce) = aOut[0], case let .sendIntent(bNonce) = bOut[0] else { return XCTFail() }
        let aOut2 = a.handle(.receivedIntent(nonce: bNonce, now: t0))
        let bOut2 = b.handle(.receivedIntent(nonce: aNonce, now: t0))
        guard case let .sendReveal(aSnap, aNonces) = aOut2[0], case let .sendReveal(bSnap, bNonces) = bOut2[0] else { return XCTFail() }
        let aReveal = try NotesExchangeCrypto.makeReveal(account: aSnap, handshakeKeys: NotesExchangePair(mine: aKey, theirs: bKey), nonces: aNonces, signer: { try aSign.signature(for: $0) })
        let bReveal = try NotesExchangeCrypto.makeReveal(account: bSnap, handshakeKeys: NotesExchangePair(mine: bKey, theirs: aKey), nonces: bNonces, signer: { try bSign.signature(for: $0) })
        guard case let .verify(pAtA, nAtA) = a.handle(.receivedReveal(bReveal, now: t0))[0],
              case let .verify(pAtB, nAtB) = b.handle(.receivedReveal(aReveal, now: t0))[0] else { return XCTFail() }
        XCTAssertTrue(NotesExchangeCrypto.verifyReveal(payload: pAtA, handshakeKeys: NotesExchangePair(mine: aKey, theirs: bKey), nonces: nAtA))
        XCTAssertTrue(NotesExchangeCrypto.verifyReveal(payload: pAtB, handshakeKeys: NotesExchangePair(mine: bKey, theirs: aKey), nonces: nAtB))
        XCTAssertEqual(pAtA.accountId, "BBBB0001")
        XCTAssertEqual(pAtB.accountId, "AAAA0001")
    }
}
