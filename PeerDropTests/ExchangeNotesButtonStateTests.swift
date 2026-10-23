import XCTest
@testable import PeerDropCore
@testable import PeerDrop

final class ExchangeNotesButtonStateTests: XCTestCase {
    private typealias P = ExchangeButtonPresentation

    private func state(_ ui: NotesExchangeSession.UIState?, supports: Bool = true, binding: BindingState = .none,
                       denial: NotesExchangeGate.Reason? = nil) -> ExchangeButtonState {
        P.state(from: ui, peerSupportsExchange: supports, bindingState: binding, gateDenial: denial)
    }

    func testEveryUIStateWhenAllowedAndUnbound() {
        XCTAssertEqual(state(nil), .idle)
        XCTAssertEqual(state(.idle), .idle)
        XCTAssertEqual(state(.waitingForPeer), .waitingForPeer)
        XCTAssertEqual(state(.peerWantsExchange), .peerWantsExchange)
        XCTAssertEqual(state(.exchanging), .verifying)
        XCTAssertEqual(state(.verifying), .verifying)
        XCTAssertEqual(state(.bound, binding: .verified), .bound)
        XCTAssertEqual(state(.bound), .needsReconnect, "session says bound but the contact is not bound")
        XCTAssertEqual(state(.peerUnavailable), .peerUnavailable)
        XCTAssertEqual(state(.expired), .expired)
        XCTAssertEqual(state(.failed(.localAccountUnavailable)), .failed(.localAccountUnavailable))
        XCTAssertEqual(state(.failed(.invalidReveal)), .failed(.couldNotConfirm))
        XCTAssertEqual(state(.failed(.verificationFailed)), .failed(.couldNotConfirm))
        XCTAssertEqual(state(.failed(.localRevealFailed)), .failed(.couldNotConfirm))
    }

    func testOldPeerIsDisabledAndExplained() {
        let s = state(nil, supports: false, denial: .peerLacksSupport)
        XCTAssertEqual(s, .unavailableOldPeer)
        XCTAssertEqual(s.action, .showInfo)
        XCTAssertEqual(state(nil, supports: false), .unavailableOldPeer)
        XCTAssertNotEqual(s.label(peerName: "Amy"), ExchangeButtonState.idle.label(peerName: "Amy"))
    }

    func testStructuralDenialsHideTheButtonWhenUnbound() {
        let denials: [NotesExchangeGate.Reason] = [.notSecured, .handshakeKeyMissing, .helloKeyMissing, .handshakeKeyMismatch,
                                                   .pinningNotEvaluated, .pinningMismatch, .notLocalDirect, .localLacksSupport]
        for d in denials { XCTAssertEqual(state(nil, denial: d), .hidden, "\(d)") }
        XCTAssertFalse(ExchangeButtonState.hidden.isVisible)
    }

    func testBindingStaysVisibleWithoutAConnection() {
        XCTAssertEqual(state(nil, binding: .verified, denial: .notSecured), .bound)
        XCTAssertEqual(state(nil, binding: .pending, denial: .notSecured), .verifying)
        XCTAssertEqual(state(nil, binding: .verified), .bound)
        XCTAssertEqual(state(.idle, binding: .verified), .bound)
        XCTAssertEqual(state(nil, binding: .pending), .verifying)
    }

    func testBindingIsTheSourceOfTruthForTheBoundBadge() {
        XCTAssertEqual(state(.bound, binding: .verified), .bound)
        // Unbound on the same connection: the session still says bound, the contact does not.
        XCTAssertEqual(state(.bound, binding: .none), .needsReconnect)
        XCTAssertEqual(state(.bound, binding: .none, denial: .notSecured), .needsReconnect)
        XCTAssertEqual(state(.bound, binding: .pending), .verifying)
    }

    func testReExchangeProgressOverridesBoundBadge() {
        XCTAssertEqual(state(.waitingForPeer, binding: .verified), .waitingForPeer)
        XCTAssertEqual(state(.peerWantsExchange, binding: .verified), .peerWantsExchange)
    }

    func testTapActionsAndEnabledness() {
        XCTAssertEqual(ExchangeButtonState.idle.action, .confirmShare)
        XCTAssertEqual(ExchangeButtonState.expired.action, .confirmShare)
        XCTAssertEqual(ExchangeButtonState.peerWantsExchange.action, .confirmAgree)
        XCTAssertEqual(ExchangeButtonState.waitingForPeer.action, .confirmWithdraw)
        XCTAssertEqual(ExchangeButtonState.bound.action, .confirmUnbind)
        XCTAssertEqual(ExchangeButtonState.hidden.action, .noAction)
        let informational: [ExchangeButtonState] = [.unavailableOldPeer, .verifying, .peerUnavailable, .needsReconnect,
                                                    .failed(.couldNotConfirm), .failed(.localAccountUnavailable)]
        for s in informational {
            XCTAssertEqual(s.action, .showInfo, "\(s)")
            XCTAssertTrue(s.isEnabled, "informational states are tappable so iOS can show the explanation")
            XCTAssertFalse(s.infoMessage(peerName: "Amy")?.isEmpty ?? true, "\(s)")
        }
        XCTAssertNil(ExchangeButtonState.idle.infoMessage(peerName: "Amy"))
        XCTAssertFalse(ExchangeButtonState.hidden.isEnabled)
    }

    func testFailureAndExpiryMessagesDiffer() {
        let failed = ExchangeButtonState.failed(.couldNotConfirm).label(peerName: "Amy")
        XCTAssertNotEqual(failed, ExchangeButtonState.expired.label(peerName: "Amy"))
        XCTAssertNotEqual(ExchangeButtonState.failed(.localAccountUnavailable).label(peerName: "Amy"), failed)
    }

    func testEveryVisibleStateHasItsOwnSymbol() {
        let all: [ExchangeButtonState] = [.unavailableOldPeer, .idle, .waitingForPeer, .peerWantsExchange, .verifying, .bound,
                                          .peerUnavailable, .needsReconnect, .expired, .failed(.couldNotConfirm)]
        let symbols = all.map(\.symbol)
        XCTAssertEqual(Set(symbols).count, symbols.count, "\(symbols)")
        XCTAssertNotEqual(ExchangeButtonState.idle.symbol, ExchangeButtonState.peerWantsExchange.symbol)
    }

    func testTransitionToasts() {
        XCTAssertNotNil(ExchangeButtonState.bound.transitionToast(peerName: "Amy"))
        XCTAssertNotNil(ExchangeButtonState.peerUnavailable.transitionToast(peerName: "Amy"))
        XCTAssertNotNil(ExchangeButtonState.failed(.couldNotConfirm).transitionToast(peerName: "Amy"))
        for s in [ExchangeButtonState.idle, .waitingForPeer, .peerWantsExchange, .verifying, .expired, .hidden, .needsReconnect] {
            XCTAssertNil(s.transitionToast(peerName: "Amy"), "\(s)")
        }
    }

    func testEveryVisibleStateHasLabelAndSymbolAndNeverClaimsVerification() {
        let all: [ExchangeButtonState] = [.unavailableOldPeer, .idle, .waitingForPeer, .peerWantsExchange, .verifying, .bound,
                                          .peerUnavailable, .needsReconnect, .expired, .failed(.localAccountUnavailable), .failed(.couldNotConfirm)]
        for s in all {
            let label = s.label(peerName: "Amy")
            XCTAssertFalse(label.isEmpty, "\(s)")
            XCTAssertFalse(s.symbol.isEmpty)
            XCTAssertFalse(label.lowercased().contains("verified"), "\(s)")
        }
        XCTAssertTrue(ExchangeButtonState.peerWantsExchange.label(peerName: "Amy").contains("Amy"))
    }
}
