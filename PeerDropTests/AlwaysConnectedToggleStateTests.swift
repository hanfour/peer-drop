import XCTest
import CryptoKit
import PeerDropCore
import PeerDropSecurity
@testable import PeerDrop

/// Project E, Task 6 — presentation logic of the per-friend "always connected" toggle.
@MainActor
final class AlwaysConnectedToggleStateTests: XCTestCase {
    typealias P = AlwaysConnectedPresentation

    private func key() -> Data { Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation }

    private func contact(bound: Bool = true, pending: Bool = false, enabled: Bool = false, blocked: Bool = false) -> TrustedContact {
        var c = TrustedContact(deviceId: "dev-\(UUID().uuidString.prefix(6))", displayName: "Ann", identityPublicKey: key(),
                               trustLevel: .verified, accountId: bound ? "acct-ann" : nil, isBlocked: blocked)
        if pending {
            c.pendingAccountBinding = PendingAccountBinding(accountId: "acct-p", signingKey: Data(repeating: 1, count: 32),
                                                            handshakeKeyHash: Data(repeating: 2, count: 32),
                                                            receivedAt: Date(timeIntervalSince1970: 1_700_000_000))
        }
        if enabled, !blocked, !pending, bound {
            // `rendezvousEnabled` is store-only (internal setter): enable through a throwaway store.
            let store = makeStore()
            store.add(c)
            try? store.setRendezvousEnabled(for: c.id, true)
            let out = store.contacts.first { $0.id == c.id } ?? c
            store.removeAll()
            return out
        }
        return c
    }

    // MARK: state(contact:enabledCount:rendezvousState:)

    func testUnboundIsUnavailableForEveryCountAndLinkState() {
        for count in 0...6 {
            for link in [RendezvousLinkState.inactive, .connecting, .connected, .unreachable] {
                XCTAssertEqual(P.state(contact: contact(bound: false), enabledCount: count, rendezvousState: link),
                               .unavailableNotBound, "count \(count) \(link)")
            }
        }
    }

    func testPendingBindingAndBlockedAreUnavailable() {
        XCTAssertEqual(P.state(contact: contact(pending: true), enabledCount: 0, rendezvousState: .inactive), .unavailableNotBound)
        XCTAssertEqual(P.state(contact: contact(blocked: true), enabledCount: 0, rendezvousState: .inactive), .unavailableNotBound)
    }

    func testStoreEligibilityOverridesSimpleCheck() {
        XCTAssertEqual(P.state(contact: contact(), enabledCount: 0, rendezvousState: .inactive, eligible: false), .unavailableNotBound)
        XCTAssertEqual(P.state(contact: contact(bound: false), enabledCount: 0, rendezvousState: .inactive, eligible: true), .off)
    }

    func testOffBelowLimit() {
        for count in 0..<P.limit {
            for link in [RendezvousLinkState.inactive, .connecting, .connected, .unreachable] {
                XCTAssertEqual(P.state(contact: contact(), enabledCount: count, rendezvousState: link), .off, "count \(count)")
            }
        }
    }

    func testLimitReachedOnlyWhenOffAndAtOrAboveLimit() {
        XCTAssertEqual(P.limit, 5)
        for count in [5, 6] {
            XCTAssertEqual(P.state(contact: contact(), enabledCount: count, rendezvousState: .inactive), .limitReached)
        }
    }

    func testEnabledFriendStillTogglesOffAtLimit() {
        // The 5th enabled friend itself is counted in enabledCount (5) and must stay "on".
        let s = P.state(contact: contact(enabled: true), enabledCount: 5, rendezvousState: .unreachable)
        XCTAssertEqual(s, .on(.waiting))
        XCTAssertTrue(P.isToggleInteractive(s))
        XCTAssertTrue(P.toggleIsOn(s))
    }

    func testOnMapsLinkStateAndHidesUnreachable() {
        let c = contact(enabled: true)
        XCTAssertEqual(P.state(contact: c, enabledCount: 1, rendezvousState: .inactive), .on(.waiting))
        XCTAssertEqual(P.state(contact: c, enabledCount: 1, rendezvousState: .connecting), .on(.connecting))
        XCTAssertEqual(P.state(contact: c, enabledCount: 1, rendezvousState: .connected), .on(.online))
        // peer not present and refused look identical: waiting.
        XCTAssertEqual(P.state(contact: c, enabledCount: 1, rendezvousState: .unreachable),
                       P.state(contact: c, enabledCount: 1, rendezvousState: .inactive))
    }

    func testToggleInteractivityAndValue() {
        XCTAssertFalse(P.isToggleInteractive(.unavailableNotBound))
        XCTAssertFalse(P.isToggleInteractive(.limitReached))
        XCTAssertTrue(P.isToggleInteractive(.off))
        for l in [P.Link.waiting, .connecting, .online] {
            XCTAssertTrue(P.isToggleInteractive(.on(l)))
            XCTAssertTrue(P.toggleIsOn(.on(l)))
        }
        for s in [P.State.off, .unavailableNotBound, .limitReached] { XCTAssertFalse(P.toggleIsOn(s)) }
    }

    // MARK: applying the toggle (typed errors)

    private func makeStore() -> TrustedContactStore {
        TrustedContactStore(storageKey: "test-ac-\(UUID().uuidString)",
                            directory: FileManager.default.temporaryDirectory.appendingPathComponent("ac-\(UUID().uuidString)"),
                            encryptor: ChatDataEncryptor(testKey: SymmetricKey(size: .bits256)))
    }

    private func addBound(_ store: TrustedContactStore, _ n: Int) -> TrustedContact {
        let c = TrustedContact(deviceId: "dev-\(n)", displayName: "F\(n)", identityPublicKey: key(), trustLevel: .verified, accountId: "acct-\(n)")
        store.add(c)
        return c
    }

    func testSixthEnableRefusedAndFirstStillTogglesOff() {
        let store = makeStore()
        defer { store.removeAll() }
        let friends = (0..<6).map { addBound(store, $0) }
        var cleared: [UUID] = []
        for f in friends.prefix(5) {
            XCTAssertEqual(P.apply(enabled: true, contactID: f.id, store: store, clearSuspension: { cleared.append($0) }), .applied)
        }
        XCTAssertEqual(P.enabledCount(in: store), 5)
        XCTAssertEqual(P.apply(enabled: true, contactID: friends[5].id, store: store, clearSuspension: { _ in }), .limitReached)
        XCTAssertFalse(store.contacts.first { $0.id == friends[5].id }!.isRendezvousEnabled)
        XCTAssertEqual(P.state(contact: store.contacts.first { $0.id == friends[5].id }!, enabledCount: P.enabledCount(in: store),
                               rendezvousState: .inactive, eligible: true), .limitReached)
        // Existing one still toggles off, and the suspension is cleared (quiet downgrade).
        cleared.removeAll()
        XCTAssertEqual(P.apply(enabled: false, contactID: friends[0].id, store: store, clearSuspension: { cleared.append($0) }), .applied)
        XCTAssertEqual(cleared, [friends[0].id])
        XCTAssertEqual(P.enabledCount(in: store), 4)
        XCTAssertEqual(P.apply(enabled: true, contactID: friends[5].id, store: store, clearSuspension: { _ in }), .applied)
    }

    func testUnboundAndUnknownEnableOutcomes() {
        let store = makeStore()
        defer { store.removeAll() }
        let unbound = TrustedContact(deviceId: "d", displayName: "U", identityPublicKey: key(), trustLevel: .verified)
        store.add(unbound)
        XCTAssertEqual(P.apply(enabled: true, contactID: unbound.id, store: store, clearSuspension: { _ in }), .unavailable)
        XCTAssertEqual(P.apply(enabled: true, contactID: UUID(), store: store, clearSuspension: { _ in }), .unknownContact)
    }

    func testFailureOutcomeMessagesAreDistinctAndNonNil() {
        XCTAssertEqual(P.messageKey(for: .limitReached), P.limitReachedKey)
        XCTAssertEqual(P.messageKey(for: .unavailable), P.unavailableKey)
        XCTAssertNil(P.messageKey(for: .applied))
        XCTAssertNil(P.messageKey(for: .unknownContact))
    }

    // MARK: strings / VoiceOver

    private var allStates: [P.State] {
        [.unavailableNotBound, .off, .on(.waiting), .on(.connecting), .on(.online), .limitReached]
    }

    func testVoiceOverNonEmptyAndDistinctPerState() {
        let texts = allStates.map { P.voiceOverText($0) }
        for t in texts { XCTAssertFalse(t.isEmpty) }
        XCTAssertEqual(Set(texts).count, allStates.count, "\(texts)")
        XCTAssertEqual(Set(allStates.map { P.voiceOverKey($0) }).count, allStates.count)
    }

    func testEveryStateHasVisibleTextExceptPlainOff() {
        for s in allStates {
            XCTAssertFalse(P.footnoteKeys(s).isEmpty, "\(s)")
        }
        XCTAssertNil(P.statusKey(.off))
        XCTAssertNil(P.statusKey(.unavailableNotBound))
        XCTAssertNotNil(P.statusKey(.on(.waiting)))
        XCTAssertNotEqual(P.statusKey(.on(.waiting)), P.statusKey(.on(.online)))
        XCTAssertNotEqual(P.statusKey(.on(.connecting)), P.statusKey(.on(.online)))
    }

    func testWaitingAndConnectingCarryTheMandatedExplanation() {
        XCTAssertTrue(P.footnoteKeys(.on(.waiting)).contains(P.explanationKey))
        XCTAssertTrue(P.footnoteKeys(.on(.connecting)).contains(P.explanationKey))
        XCTAssertTrue(P.footnoteKeys(.off).contains(P.explanationKey))
        XCTAssertTrue(P.footnoteKeys(.unavailableNotBound).contains(P.unavailableKey))
        XCTAssertTrue(P.footnoteKeys(.limitReached).contains(P.limitReachedKey))
        XCTAssertEqual(P.explanationKey, "The green dot shows only when your friend has also turned this on and is online.")
    }

    // MARK: file / call / info

    func testFileAndCallOfferingFollowsConnectionKind() {
        XCTAssertFalse(P.offersFileTransferAndCalls(isRendezvousConnection: true))
        XCTAssertTrue(P.offersFileTransferAndCalls(isRendezvousConnection: false))
        XCTAssertEqual(P.infoDestination(isRendezvousConnection: true), .alwaysConnectedSheet)
        XCTAssertEqual(P.infoDestination(isRendezvousConnection: false), .connectionView)
    }

    func testKeyChangedItemOnlyForKeyRelatedReasons() {
        let all: [RendezvousConnectionFailure] = [.keyMismatch, .bindingFailed, .helloMismatch, .helloMismatchUnauthenticated,
                                                  .timeout, .decryptFailed, .channelFailed, .installRefused, .connectionClosed]
        let key: Set<RendezvousConnectionFailure> = [.keyMismatch, .helloMismatch, .helloMismatchUnauthenticated]
        for r in all { XCTAssertEqual(P.showsKeyChangedItem(reason: r), key.contains(r), "\(r)") }
        XCTAssertFalse(P.showsKeyChangedItem(reason: nil))
    }

    // MARK: localization scan

    private static let languages = ["en", "zh-Hant", "zh-Hans", "ja", "ko"]

    /// Wording that would tell the user what the OTHER side did (or imply a block/downgrade).
    static let forbiddenFragments: [String] = [
        // zh-Hant / zh-Hans
        "對方已開啟", "對方已關閉", "對方已經開啟", "對方已經關閉", "已降級", "被關閉", "被降級", "封鎖", "對方關閉了", "對方關掉",
        "对方已开启", "对方已关闭", "对方已经开启", "对方已经关闭", "被关闭", "被降级", "封锁", "对方关闭了", "对方关掉",
        // en
        "turned off", "turned you off", "disabled you", "has disabled", "downgrad", "blocked you", "blocked", "switched off",
        "offline because",
        // ja
        "相手がオフ", "相手がオン", "相手が無効", "ダウングレード", "ブロック", "オフにされ", "無効にされ",
        // ko
        "상대가 껐", "상대방이 껐", "상대방이 꺼", "다운그레이드", "차단", "비활성화했",
    ]

    private func catalog() throws -> [String: [String: String]] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PeerDrop/App/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        var out: [String: [String: String]] = [:]
        for key in P.allLocalizedKeys {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "missing catalog key: \(key)")
            let locs = try XCTUnwrap(entry["localizations"] as? [String: Any], "no localizations: \(key)")
            var perLang: [String: String] = [:]
            for lang in Self.languages {
                let l = try XCTUnwrap(locs[lang] as? [String: Any], "\(key) missing \(lang)")
                let unit = try XCTUnwrap(l["stringUnit"] as? [String: Any], "\(key) \(lang) no stringUnit")
                XCTAssertEqual(unit["state"] as? String, "translated", "\(key) \(lang) state")
                let v = try XCTUnwrap(unit["value"] as? String)
                XCTAssertFalse(v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(key) \(lang) empty")
                perLang[lang] = v
            }
            out[key] = perLang
        }
        return out
    }

    func testAllKeysPresentInAllFiveLanguages() throws {
        let c = try catalog()
        XCTAssertEqual(c.count, P.allLocalizedKeys.count)
        XCTAssertGreaterThanOrEqual(P.allLocalizedKeys.count, 20)
        XCTAssertEqual(Set(P.allLocalizedKeys).count, P.allLocalizedKeys.count, "duplicate keys")
        // English value equals the key (source language).
        for (k, v) in c { XCTAssertEqual(v["en"], k) }
    }

    func testNoForbiddenWordingInAnyLanguage() throws {
        for (key, langs) in try catalog() {
            for (lang, value) in langs {
                for bad in Self.forbiddenFragments where value.localizedCaseInsensitiveContains(bad) {
                    XCTFail("'\(bad)' found in \(key) [\(lang)]: \(value)")
                }
            }
        }
    }

    func testNoDuplicateSymbolKeys() {
        func symbol(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let syms = P.allLocalizedKeys.map(symbol)
        XCTAssertEqual(Set(syms).count, syms.count)
    }

    func testMandatedWaitingCopyTranslations() throws {
        let c = try catalog()[P.explanationKey]
        XCTAssertEqual(c?["zh-Hant"], "對方也開啟並在線時才會顯示綠點")
    }

    func testConfirmOffTextMatchesMandatedWording() throws {
        let c = try catalog()[P.turnOffMessageKey]
        XCTAssertEqual(c?["zh-Hant"], "關閉後你在他那邊會顯示離線")
    }

    func testKeyChangedTextMatchesMandatedWording() throws {
        let c = try catalog()[P.keyChangedKey]
        XCTAssertEqual(c?["zh-Hant"], "這位朋友的金鑰可能已更換，請當面重新配對")
    }

    func testExplainerCoversRequiredTopics() {
        let keys = P.explainerSections.flatMap { $0.bodyKeys }
        XCTAssertGreaterThanOrEqual(keys.count, 8)
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertTrue(P.allLocalizedKeys.contains(P.explainerTitleKey))
        for k in keys { XCTAssertTrue(P.allLocalizedKeys.contains(k)) }
    }
}
