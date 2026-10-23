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
        XCTAssertEqual(state(.bound), .bound)
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
        XCTAssertFalse(s.isEnabled)
        XCTAssertEqual(state(nil, supports: false), .unavailableOldPeer)
        XCTAssertTrue(s.label(peerName: "Amy").contains("update"))
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

    func testReExchangeProgressOverridesBoundBadge() {
        XCTAssertEqual(state(.waitingForPeer, binding: .verified), .waitingForPeer)
        XCTAssertEqual(state(.peerWantsExchange, binding: .verified), .peerWantsExchange)
    }

    func testTapActionsAndEnabledness() {
        XCTAssertEqual(ExchangeButtonState.idle.action, .confirmShare)
        XCTAssertEqual(ExchangeButtonState.peerWantsExchange.action, .confirmShare)
        XCTAssertEqual(ExchangeButtonState.expired.action, .confirmShare)
        XCTAssertEqual(ExchangeButtonState.waitingForPeer.action, .confirmWithdraw)
        XCTAssertEqual(ExchangeButtonState.bound.action, .confirmUnbind)
        let inert: [ExchangeButtonState] = [.hidden, .unavailableOldPeer, .verifying, .peerUnavailable,
                                            .failed(.couldNotConfirm), .failed(.localAccountUnavailable)]
        for s in inert { XCTAssertFalse(s.isEnabled, "\(s)") }
        for s in [ExchangeButtonState.idle, .peerWantsExchange, .expired, .waitingForPeer, .bound] { XCTAssertTrue(s.isEnabled) }
    }

    func testEveryVisibleStateHasLabelAndSymbolAndNeverClaimsVerification() {
        let all: [ExchangeButtonState] = [.unavailableOldPeer, .idle, .waitingForPeer, .peerWantsExchange, .verifying, .bound,
                                          .peerUnavailable, .expired, .failed(.localAccountUnavailable), .failed(.couldNotConfirm)]
        for s in all {
            let label = s.label(peerName: "Amy")
            XCTAssertFalse(label.isEmpty, "\(s)")
            XCTAssertFalse(s.symbol.isEmpty)
            XCTAssertFalse(label.lowercased().contains("verified"), "\(s)")
        }
        XCTAssertTrue(ExchangeButtonState.peerWantsExchange.label(peerName: "Amy").contains("Amy"))
    }
}
