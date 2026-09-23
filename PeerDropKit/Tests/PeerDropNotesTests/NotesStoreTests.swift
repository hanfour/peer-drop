import XCTest
import CryptoKit
import PeerDropSecurity
import PeerDropAccount
@testable import PeerDropNotes

@MainActor
final class NotesStoreTests: XCTestCase {
    private var me: RecipientFixture!          // this device = recipient "TESTRCPT"
    private var store: NotesStore!
    private var dir: URL!

    private struct FakeCrypto: NotesCryptoContext {
        let fixture: RecipientFixture
        let signing = Curve25519.Signing.PrivateKey()
        func recipientKeys() throws -> NoteRecipientKeys { fixture.keys() }
        func signer(accountId: String, nickname: String?) throws -> NoteSigner {
            NoteSigner(accountId: accountId, nickname: nickname, signingPublicKey: signing.publicKey.rawRepresentation, sign: { try self.signing.signature(for: $0) })
        }
    }

    override func setUp() async throws {
        TestURLProtocol.reset()
        me = try RecipientFixture()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("notes-store-\(UUID().uuidString)", isDirectory: true)
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [TestURLProtocol.self]
        let account = AccountClient(baseURL: URL(string: "https://worker.test")!, session: URLSession(configuration: cfg), authProvider: { _ in }, tokenInvalidator: {})
        let manager = AccountManager(mock: Account(accountId: me.accountId, nickname: "rcpt", mailboxId: "mbxtest", createdAt: Date()))
        store = NotesStore(client: NotesClient(account: account), accountManager: manager, crypto: FakeCrypto(fixture: me),
                           storage: NotesStorage(directory: dir, encryptor: ChatDataEncryptor(testKey: SymmetricKey(size: .bits256))))
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func inboxJSON(_ items: [(id: String, envelope: NoteEnvelope)], nextAfter: String? = nil) throws -> Data {
        let arr = try items.map { #"{"id":"\#($0.id)","kind":"note","envelope":"\#(try $0.envelope.wireBytes().base64EncodedString())","createdAt":1700000000000,"readAt":null}"# }
        let next = nextAfter.map { #","nextAfter":"\#($0)""# } ?? ""
        return Data(#"{"items":[\#(arr.joined(separator: ","))]\#(next)}"#.utf8)
    }
    private func directoryJSON(signingKey: Data, nickname: String = "alice") -> Data {
        Data(#"{"accountId":"SENDR001","nickname":"\#(nickname)","identityKey":"AAAA","signingKey":"\#(signingKey.base64EncodedString())","mailboxId":"m"}"#.utf8)
    }

    /// Builds a `diaryKey` envelope with `sender == nil` — `NoteCrypto.seal`
    /// itself refuses this (`.signerRequired`), by design: our own client
    /// never sends an anonymous key relay. But a hostile/buggy sender that
    /// bypasses this library entirely could still put such a plaintext on
    /// the wire, and `NotesStore` must treat it as anonymous (§3.4) rather
    /// than crash or trust it — so this replicates just enough of `seal`'s
    /// crypto (via `@testable` access to its internal `aad`/`noteKey(from:)`
    /// helpers) to produce that wire shape directly.
    private func sealAnonymousDiaryKey(text: String, recipient: DirectoryEntry) throws -> NoteEnvelope {
        let bundle = recipient.preKeyBundle!
        let identity = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipient.identityKey)
        let signingKey = try Curve25519.Signing.PublicKey(rawRepresentation: recipient.signingKey)
        let spk = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: bundle.signedPreKey.publicKey)
        let peerVersion = try X3DH.verifyBundleFreshness(signedPreKeyPublicKey: bundle.signedPreKey.publicKey, signedPreKeyTimestamp: bundle.signedPreKeyTimestamp,
                                                          signedPreKeyTimestampSignature: bundle.signedPreKeyTimestampSignature, peerSigningKey: signingKey,
                                                          now: Date(), policy: .bundledDefault, metrics: nil)
        let opk = try bundle.oneTimePreKey.map { try Curve25519.KeyAgreement.PublicKey(rawRepresentation: $0.publicKey) }
        let ek1 = Curve25519.KeyAgreement.PrivateKey()
        let ek2 = Curve25519.KeyAgreement.PrivateKey()
        let agreement = try X3DH.initiatorKeyAgreement(myIdentityKey: ek1, myEphemeralKey: ek2, theirIdentityKey: identity,
                                                        theirSignedPreKey: spk, theirOneTimePreKey: opk, peerVersion: peerVersion, policy: .bundledDefault)
        let plaintext = try JSONEncoder().encode(NotePlaintext(kind: .diaryKey, text: text, sentAt: Int64(Date().timeIntervalSince1970), sender: nil))
        let nonce = AES.GCM.Nonce()
        let box = try AES.GCM.seal(plaintext, using: NoteCrypto.noteKey(from: agreement), nonce: nonce,
                                   authenticating: NoteCrypto.aad(recipientAccountId: recipient.accountId.raw, version: NoteEnvelope.currentVersion))
        var combined = Data(box.ciphertext)
        combined.append(box.tag)
        return NoteEnvelope(v: NoteEnvelope.currentVersion, ephemeralKey: ek1.publicKey.rawRepresentation, ephemeralKey2: ek2.publicKey.rawRepresentation,
                            spkId: bundle.signedPreKey.id, opkId: bundle.oneTimePreKey?.id, nonce: Data(nonce), ciphertext: combined)
    }

    func testSyncDecryptsAnonymousNoteAndDedupes() async throws {
        let env = try NoteCrypto.seal(text: "hi there", recipient: try me.entry(), signer: nil)
        TestURLProtocol.queue = [.init(status: 200, body: try inboxJSON([("01AAAAAAAAAAAAAAAAAAAAAAAA", env)]))]
        await store.sync()
        XCTAssertEqual(store.inbox.map(\.text), ["hi there"])
        XCTAssertEqual(store.inbox[0].sender, .anonymous)
        XCTAssertEqual(store.unreadCount, 1)
        XCTAssertEqual(TestURLProtocol.requests[0].url?.path, "/v3/inbox")
        // Second sync: the cursor advanced and a repeated item is not duplicated.
        TestURLProtocol.queue = [.init(status: 200, body: try inboxJSON([("01AAAAAAAAAAAAAAAAAAAAAAAA", env)]))]
        await store.sync()
        XCTAssertEqual(store.inbox.count, 1)
        XCTAssertEqual(TestURLProtocol.requests[1].url?.query, "after=01AAAAAAAAAAAAAAAAAAAAAAAA&limit=50")
    }
    func testSyncFollowsNextAfterAcrossPages() async throws {
        let env1 = try NoteCrypto.seal(text: "page one", recipient: try me.entry(), signer: nil)
        let env2 = try NoteCrypto.seal(text: "page two", recipient: try me.entry(), signer: nil)
        let id1 = "01AAAAAAAAAAAAAAAAAAAAAAAF"
        let id2 = "01AAAAAAAAAAAAAAAAAAAAAAAG"
        TestURLProtocol.queue = [
            .init(status: 200, body: try inboxJSON([(id1, env1)], nextAfter: id1)),
            .init(status: 200, body: try inboxJSON([(id2, env2)], nextAfter: nil)),
        ]
        await store.sync()
        XCTAssertEqual(Set(store.inbox.map(\.id)), Set([id1, id2]))
        XCTAssertEqual(TestURLProtocol.requests[1].url?.query, "after=\(id1)&limit=50")
        XCTAssertEqual(store.storage.lastSeenInboxId, id2)
    }
    func testSyncRateLimitedMapsError() async throws {
        TestURLProtocol.queue = [.init(status: 429, body: Data(#"{"error":"rate_limited"}"#.utf8))]
        await store.sync()
        XCTAssertTrue(store.inbox.isEmpty)
        XCTAssertFalse(store.isSyncing)
        XCTAssertEqual(store.lastError, String(describing: NotesStoreError.rateLimited))
    }
    func testSyncVerifiesSignedSenderViaDirectory() async throws {
        let sender = SenderFixture()
        let env = try NoteCrypto.seal(text: "signed", recipient: try me.entry(), signer: sender.signer)
        TestURLProtocol.queue = [.init(status: 200, body: try inboxJSON([("01AAAAAAAAAAAAAAAAAAAAAAAB", env)])), .init(status: 200, body: directoryJSON(signingKey: sender.signing.publicKey.rawRepresentation))]
        await store.sync()
        XCTAssertEqual(store.inbox[0].sender, .verified(accountId: "SENDR001", nickname: "alice"))
        XCTAssertEqual(TestURLProtocol.requests[1].url?.path, "/v3/directory/SENDR001")
    }
    func testSyncMarksSenderUnverifiedWhenDirectoryKeyDiffersOrLookupFails() async throws {
        let sender = SenderFixture()
        let env = try NoteCrypto.seal(text: "s", recipient: try me.entry(), signer: sender.signer)
        TestURLProtocol.queue = [.init(status: 200, body: try inboxJSON([("01AAAAAAAAAAAAAAAAAAAAAAAC", env)])), .init(status: 200, body: directoryJSON(signingKey: Data(repeating: 9, count: 32)))]
        await store.sync()
        XCTAssertEqual(store.inbox[0].sender, .unverified(accountId: "SENDR001"))
    }
    func testTransientDirectoryFailureDoesNotPermanentlyDowngradeSender() async throws {
        let sender = SenderFixture()
        let env = try NoteCrypto.seal(text: "s", recipient: try me.entry(), signer: sender.signer)
        let id = "01AAAAAAAAAAAAAAAAAAAAAAAZ"
        // First sync: the inbox page is the only queued stub, so every
        // directory lookup (the initial `decode` and the same-sync bounded
        // re-verification pass) falls through `TestURLProtocol`'s empty-queue
        // default of a 500 — a transient failure, not a 404.
        TestURLProtocol.queue = [.init(status: 200, body: try inboxJSON([(id, env)]))]
        await store.sync()
        XCTAssertEqual(store.inbox[0].sender, .unverified(accountId: "SENDR001"))
        XCTAssertNotNil(store.inbox[0].senderBlock)
        // Second sync: the inbox item is already known so `decode` is not
        // re-run; only the bounded re-verification pass looks the sender up
        // again, this time the directory answers with the right key.
        TestURLProtocol.queue = [.init(status: 200, body: try inboxJSON([(id, env)])), .init(status: 200, body: directoryJSON(signingKey: sender.signing.publicKey.rawRepresentation))]
        await store.sync()
        XCTAssertEqual(store.inbox[0].sender, .verified(accountId: "SENDR001", nickname: "alice"))
    }
    /// Deterministic clock injected into `DirectoryCache` so this test can
    /// force cache expiry between two `sync()` calls without depending on
    /// real wall-clock speed (`DirectoryCache(ttl: 0)` alone doesn't work:
    /// empirically, even the microseconds between `decode`'s own lookup and
    /// the SAME sync's reverify pass are enough real elapsed time to exceed
    /// a zero ttl, so the mismatch is never actually cached long enough to
    /// be discovered as `.found` — it just free-falls to `.failed` on every
    /// call instead, which proves nothing about `confirmedMismatchIds`).
    private final class TestClock { var now = Date() }

    func testKeyMismatchStaysUnverifiedWithoutFurtherLookups() async throws {
        // A generous ttl keeps the FIRST sync's decode-then-reverify lookups
        // (microseconds apart) sharing one cache entry, so the mismatch is
        // discovered normally; advancing the clock past the ttl before the
        // SECOND sync then makes that cache entry stale, isolating the
        // "no second lookup" assertion to `confirmedMismatchIds` rather
        // than cache reuse.
        let clock = TestClock()
        let localDir = FileManager.default.temporaryDirectory.appendingPathComponent("notes-store-mismatch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: localDir) }
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [TestURLProtocol.self]
        let account = AccountClient(baseURL: URL(string: "https://worker.test")!, session: URLSession(configuration: cfg), authProvider: { _ in }, tokenInvalidator: {})
        let manager = AccountManager(mock: Account(accountId: me.accountId, nickname: "rcpt", mailboxId: "mbxtest", createdAt: Date()))
        let localStore = NotesStore(client: NotesClient(account: account), accountManager: manager, crypto: FakeCrypto(fixture: me),
                                    storage: NotesStorage(directory: localDir, encryptor: ChatDataEncryptor(testKey: SymmetricKey(size: .bits256))),
                                    directoryCache: DirectoryCache(ttl: 60, now: { clock.now }))
        let sender = SenderFixture()
        let env = try NoteCrypto.seal(text: "s", recipient: try me.entry(), signer: sender.signer)
        let id = "01AAAAAAAAAAAAAAAAAAAAAAAY"
        TestURLProtocol.queue = [.init(status: 200, body: try inboxJSON([(id, env)])), .init(status: 200, body: directoryJSON(signingKey: Data(repeating: 9, count: 32)))]
        await localStore.sync()
        XCTAssertEqual(localStore.inbox[0].sender, .unverified(accountId: "SENDR001"))
        let requestsAfterFirstSync = TestURLProtocol.requests.count
        // Expire the cache entry before the second sync — if `confirmedMismatchIds`
        // weren't gating the retry, a stale cache would force a real lookup,
        // which would consume the default 500 and stay unverified anyway,
        // so assert on the request COUNT to prove no lookup ran at all.
        clock.now.addTimeInterval(61)
        TestURLProtocol.queue = [.init(status: 200, body: try inboxJSON([(id, env)]))]
        await localStore.sync()
        XCTAssertEqual(localStore.inbox[0].sender, .unverified(accountId: "SENDR001"))
        XCTAssertEqual(TestURLProtocol.requests.count, requestsAfterFirstSync + 1)   // only the inbox page; no directory call
    }
    func testReverifySenderSkipsAndDoesNotCorruptAnotherRecordWhenItsOwnRecordVanishes() async throws {
        // `NotesStore` is `@MainActor`, but the actor is released for the
        // duration of `reverifySender`'s own `await directoryLookup` — a
        // concurrently issued `delete(_:)` can remove the very record a
        // pending lookup is about to answer for. Rather than race real
        // concurrency (flaky: `TestURLProtocol`'s stub queue is a single
        // global FIFO shared by every in-flight request, so a second
        // request racing the first can steal its stub), simulate the
        // post-await state directly: delete the record, THEN hand
        // `reverifySender` its now-stale id/block, exactly what it would
        // see if the delete had happened while the lookup was in flight.
        let sender = SenderFixture()
        let envA = try NoteCrypto.seal(text: "a", recipient: try me.entry(), signer: sender.signer)
        let idA = "01AAAAAAAAAAAAAAAAAAAAAAA1"
        // recordB: a plain anonymous note, unrelated to this pass — proves
        // a stale index/reference can never stamp recordA's identity onto
        // whatever now occupies its old slot.
        let envB = try NoteCrypto.seal(text: "b", recipient: try me.entry(), signer: nil)
        let idB = "01AAAAAAAAAAAAAAAAAAAAAAA2"
        TestURLProtocol.queue = [.init(status: 200, body: try inboxJSON([(idA, envA), (idB, envB)]))]
        await store.sync()
        XCTAssertEqual(Set(store.inbox.map(\.id)), Set([idA, idB]))
        let recordA = try XCTUnwrap(store.inbox.first { $0.id == idA })
        XCTAssertEqual(recordA.sender, .unverified(accountId: "SENDR001"))
        let blockA = try XCTUnwrap(recordA.senderBlock)
        XCTAssertEqual(store.inbox.first { $0.id == idB }?.sender, .anonymous)

        // Simulate recordA being deleted while its own lookup was in flight.
        await store.delete(recordA)
        XCTAssertEqual(store.inbox.map(\.id), [idB])

        // A directory answer that WOULD verify recordA arrives late.
        TestURLProtocol.queue = [.init(status: 200, body: directoryJSON(signingKey: sender.signing.publicKey.rawRepresentation))]
        let account = Account(accountId: me.accountId, nickname: "rcpt", mailboxId: "mbxtest", createdAt: Date())
        let outcome = await store.reverifySender(id: idA, block: blockA, account: account)
        guard case .found = outcome else { return XCTFail("expected the directory lookup to still succeed") }

        // The bug this guards against: writing recordA's verified identity
        // into whatever now sits at the stale index. recordB must be
        // untouched, and nothing should have crashed getting here.
        XCTAssertEqual(store.inbox.map(\.id), [idB])
        XCTAssertEqual(store.inbox[0].sender, .anonymous)
    }
    func testUndecryptableItemIsKeptWithNilText() async throws {
        let junk = NoteEnvelope(v: 1, ephemeralKey: Data(repeating: 1, count: 32), ephemeralKey2: Data(repeating: 2, count: 32), spkId: 99, opkId: nil, nonce: Data(count: 12), ciphertext: Data(count: 32))
        TestURLProtocol.queue = [.init(status: 200, body: try inboxJSON([("01AAAAAAAAAAAAAAAAAAAAAAAD", junk)]))]
        await store.sync()
        XCTAssertEqual(store.inbox.count, 1)
        XCTAssertNil(store.inbox[0].text)
        XCTAssertTrue(store.inbox[0].isUndecryptable)
    }
    // MARK: - diaryKey inbox disposition (spec §3.4)

    func testDiaryKeyInstalledDeletesAndAdvancesCursorWithoutARecord() async throws {
        let sender = SenderFixture()
        let env = try NoteCrypto.seal(text: "keyjson", recipient: try me.entry(), signer: sender.signer, kind: .diaryKey)
        let id = "01AAAAAAAAAAAAAAAAAAAAAAK1"
        var handlerCalls: [(NoteKind, NoteSenderState, String)] = []
        store.diaryKeyHandler = { plaintext, sender, itemId in
            handlerCalls.append((plaintext.kind, sender, itemId))
            return .installed
        }
        TestURLProtocol.queue = [
            .init(status: 200, body: try inboxJSON([(id, env)])),
            .init(status: 200, body: directoryJSON(signingKey: sender.signing.publicKey.rawRepresentation)),
            .init(status: 204, body: Data()),
        ]
        await store.sync()
        XCTAssertTrue(store.inbox.isEmpty)
        XCTAssertEqual(handlerCalls.count, 1)
        XCTAssertEqual(handlerCalls[0].0, .diaryKey)
        XCTAssertEqual(handlerCalls[0].1, .verified(accountId: "SENDR001", nickname: "alice"))
        XCTAssertEqual(handlerCalls[0].2, id)
        XCTAssertEqual(TestURLProtocol.requests.last?.httpMethod, "DELETE")
        XCTAssertEqual(TestURLProtocol.requests.last?.url?.path, "/v3/inbox/\(id)")
        XCTAssertEqual(store.storage.lastSeenInboxId, id)
    }
    func testDiaryKeyRejectedDeletesAndAdvancesCursorWithoutARecord() async throws {
        let sender = SenderFixture()
        let env = try NoteCrypto.seal(text: "keyjson", recipient: try me.entry(), signer: sender.signer, kind: .diaryKey)
        let id = "01AAAAAAAAAAAAAAAAAAAAAAK2"
        store.diaryKeyHandler = { _, _, _ in .rejected }
        TestURLProtocol.queue = [
            .init(status: 200, body: try inboxJSON([(id, env)])),
            .init(status: 200, body: directoryJSON(signingKey: sender.signing.publicKey.rawRepresentation)),
            .init(status: 204, body: Data()),
        ]
        await store.sync()
        XCTAssertTrue(store.inbox.isEmpty)
        XCTAssertEqual(TestURLProtocol.requests.last?.httpMethod, "DELETE")
        XCTAssertEqual(TestURLProtocol.requests.last?.url?.path, "/v3/inbox/\(id)")
        XCTAssertEqual(store.storage.lastSeenInboxId, id)
    }
    func testDiaryKeyTransientAbortsRestOfSyncRound() async throws {
        let sender = SenderFixture()
        let diaryEnv = try NoteCrypto.seal(text: "keyjson", recipient: try me.entry(), signer: sender.signer, kind: .diaryKey)
        let noteEnv = try NoteCrypto.seal(text: "hello after", recipient: try me.entry(), signer: nil)
        let diaryId = "01AAAAAAAAAAAAAAAAAAAAAAT1"
        let noteId = "01AAAAAAAAAAAAAAAAAAAAAAT2"
        store.diaryKeyHandler = { _, _, _ in .transient }
        TestURLProtocol.queue = [
            .init(status: 200, body: try inboxJSON([(diaryId, diaryEnv), (noteId, noteEnv)])),
            .init(status: 200, body: directoryJSON(signingKey: sender.signing.publicKey.rawRepresentation)),
        ]
        await store.sync()
        // The following note in the SAME page must not be processed this
        // round — the cursor is a single high-water mark, so persisting it
        // would let the reader skip past the still-unresolved diaryKey item.
        XCTAssertTrue(store.inbox.isEmpty)
        XCTAssertNil(store.storage.lastSeenInboxId)
        XCTAssertFalse(TestURLProtocol.requests.contains { $0.httpMethod == "DELETE" })
    }
    func testAnonymousDiaryKeyIsRejectedWithoutInvokingHandler() async throws {
        let env = try sealAnonymousDiaryKey(text: "keyjson", recipient: try me.entry())
        let id = "01AAAAAAAAAAAAAAAAAAAAAAAN"
        var handlerCalled = false
        store.diaryKeyHandler = { _, _, _ in handlerCalled = true; return .installed }
        TestURLProtocol.queue = [
            .init(status: 200, body: try inboxJSON([(id, env)])),
            .init(status: 204, body: Data()),
        ]
        await store.sync()
        XCTAssertFalse(handlerCalled)
        XCTAssertTrue(store.inbox.isEmpty)
        XCTAssertEqual(TestURLProtocol.requests.last?.httpMethod, "DELETE")
        XCTAssertEqual(TestURLProtocol.requests.last?.url?.path, "/v3/inbox/\(id)")
        XCTAssertEqual(store.storage.lastSeenInboxId, id)
    }
    func testDiaryKeyWithNoHandlerIsTransientWithoutDirectoryLookup() async throws {
        let sender = SenderFixture()
        let env = try NoteCrypto.seal(text: "keyjson", recipient: try me.entry(), signer: sender.signer, kind: .diaryKey)
        let id = "01AAAAAAAAAAAAAAAAAAAAAANH"
        // store.diaryKeyHandler left nil (default).
        TestURLProtocol.queue = [.init(status: 200, body: try inboxJSON([(id, env)]))]
        await store.sync()
        XCTAssertTrue(store.inbox.isEmpty)
        XCTAssertNil(store.storage.lastSeenInboxId)
        XCTAssertEqual(TestURLProtocol.requests.count, 1)   // just the inbox page — no directory lookup, no delete
    }
    func testDiaryKeyWithMismatchedDirectoryKeyStillReachesHandlerUnverified() async throws {
        let sender = SenderFixture()
        let env = try NoteCrypto.seal(text: "keyjson", recipient: try me.entry(), signer: sender.signer, kind: .diaryKey)
        let id = "01AAAAAAAAAAAAAAAAAAAAAAM1"
        var receivedState: NoteSenderState?
        store.diaryKeyHandler = { _, state, _ in receivedState = state; return .rejected }
        TestURLProtocol.queue = [
            .init(status: 200, body: try inboxJSON([(id, env)])),
            .init(status: 200, body: directoryJSON(signingKey: Data(repeating: 9, count: 32))),   // mismatched key
            .init(status: 204, body: Data()),
        ]
        await store.sync()
        XCTAssertEqual(receivedState, .unverified(accountId: "SENDR001"))
        XCTAssertTrue(store.inbox.isEmpty)
        XCTAssertEqual(store.storage.lastSeenInboxId, id)
    }

    // MARK: - I3: a transient directory failure must never destroy a relayed key

    /// The handler maps `.unverified` → `.rejected`, and this layer then
    /// DELETEs the inbox item and advances the cursor — permanently
    /// destroying the only copy of the relayed diary key (the sender's own
    /// 24h dedupe means no re-relay for a day). So a lookup that merely
    /// FAILED (network/429/500 — as opposed to a definitive "no such
    /// account" or a key mismatch) must not be allowed to produce
    /// `.unverified` at all: the item is kept, the cursor stays put, and
    /// the handler is never invoked.
    func testDiaryKeyWithATransientDirectoryFailureIsTransientAndNeverReachesTheHandler() async throws {
        let sender = SenderFixture()
        let env = try NoteCrypto.seal(text: "keyjson", recipient: try me.entry(), signer: sender.signer, kind: .diaryKey)
        let id = "01AAAAAAAAAAAAAAAAAAAAAAD1"
        var handlerCalled = false
        store.diaryKeyHandler = { _, _, _ in handlerCalled = true; return .rejected }
        // Only the inbox page is stubbed: the directory lookup falls through
        // `TestURLProtocol`'s empty-queue default of a 500 — transient, not a 404.
        TestURLProtocol.queue = [.init(status: 200, body: try inboxJSON([(id, env)]))]
        await store.sync()
        XCTAssertFalse(handlerCalled)
        XCTAssertTrue(store.inbox.isEmpty)                                                  // never becomes a NoteRecord either way
        XCTAssertNil(store.storage.lastSeenInboxId)                                         // cursor NOT advanced
        XCTAssertFalse(TestURLProtocol.requests.contains { $0.httpMethod == "DELETE" })     // server-side item kept
        XCTAssertEqual(TestURLProtocol.requests.count, 2)                                   // inbox page + the one failed lookup
    }

    /// The other half of the same split: a definitive 404 from the directory
    /// is a permanent answer, so it still reaches the handler as
    /// `.unverified` (→ rejected → delete + cursor advance), exactly as
    /// before. The `.found`-and-matching case is covered by
    /// `testDiaryKeyInstalledDeletesAndAdvancesCursorWithoutARecord` above
    /// (and, on the handler side, by `DiaryStoreTests`'
    /// `testAcceptRelayedKeyInstallsWhenSenderIsAVerifiedMemberAndTheKeyOpensMetaCipher`).
    func testDiaryKeyWithADirectory404StillReachesTheHandlerUnverifiedAndIsDeleted() async throws {
        let sender = SenderFixture()
        let env = try NoteCrypto.seal(text: "keyjson", recipient: try me.entry(), signer: sender.signer, kind: .diaryKey)
        let id = "01AAAAAAAAAAAAAAAAAAAAAAD2"
        var receivedState: NoteSenderState?
        store.diaryKeyHandler = { _, state, _ in receivedState = state; return .rejected }
        TestURLProtocol.queue = [
            .init(status: 200, body: try inboxJSON([(id, env)])),
            .init(status: 404, body: Data(#"{"error":"not_found"}"#.utf8)),
            .init(status: 204, body: Data()),
        ]
        await store.sync()
        XCTAssertEqual(receivedState, .unverified(accountId: "SENDR001"))
        XCTAssertTrue(store.inbox.isEmpty)
        XCTAssertEqual(TestURLProtocol.requests.last?.httpMethod, "DELETE")
        XCTAssertEqual(TestURLProtocol.requests.last?.url?.path, "/v3/inbox/\(id)")
        XCTAssertEqual(store.storage.lastSeenInboxId, id)
    }

    func testSendLooksUpBundleSealsSolvesAndStores() async throws {
        let recipient = try RecipientFixture()   // someone else; we only need their public bundle
        let entry = try recipient.entry()
        let bundle = entry.preKeyBundle!
        let dirBody = Data(#"{"accountId":"TESTRCPT","nickname":"bob","identityKey":"\#(entry.identityKey.base64EncodedString())","signingKey":"\#(entry.signingKey.base64EncodedString())","mailboxId":"m","preKeyBundle":\#(String(decoding: try JSONEncoder().encode(bundle), as: UTF8.self))}"#.utf8)
        TestURLProtocol.queue = [.init(status: 200, body: dirBody), .init(status: 200, body: Data(#"{"challenge":"Q0hBTA=="}"#.utf8)), .init(status: 201, body: Data(#"{"id":"01SENT000000000000000000AA"}"#.utf8))]
        let rec = try await store.send(text: "yo", to: "test-rcpt", anonymous: false)
        XCTAssertEqual(rec.id, "01SENT000000000000000000AA"); XCTAssertEqual(rec.direction, .outbound); XCTAssertEqual(rec.text, "yo")
        XCTAssertEqual(rec.sender, .verified(accountId: "TESTRCPT", nickname: "rcpt"))
        XCTAssertEqual(store.sent.map(\.id), [rec.id])
        XCTAssertEqual(TestURLProtocol.requests[0].url?.path, "/v3/directory/test-rcpt"); XCTAssertEqual(TestURLProtocol.requests[0].url?.query, "bundle=1")
        XCTAssertEqual(TestURLProtocol.requests[2].url?.path, "/v3/notes/TESTRCPT")
        let body = try JSONSerialization.jsonObject(with: TestURLProtocol.requests[2].httpBody!) as! [String: Any]
        let envB64 = body["envelope"] as! String
        let opened = try NoteCrypto.open(try NoteEnvelope.fromWire(Data(base64Encoded: envB64)!), recipientAccountId: "TESTRCPT", keys: recipient.keys())
        XCTAssertEqual(opened.text, "yo"); XCTAssertEqual(opened.sender?.accountId, "TESTRCPT")
        let pow = body["pow"] as! [String: Any]
        XCTAssertEqual(pow["challenge"] as? String, "Q0hBTA==")
        XCTAssertTrue(ProofOfWork.verify(challenge: NoteProofOfWork.message(challenge: "Q0hBTA==", recipientAccountId: "TESTRCPT", envelopeBytes: Data(base64Encoded: envB64)!), proof: UInt64(pow["nonce"] as! Int), difficulty: 16))
    }
    func testSendAnonymousHasNoSenderBlock() async throws {
        let recipient = try RecipientFixture(); let entry = try recipient.entry()
        let dirBody = Data(#"{"accountId":"TESTRCPT","nickname":null,"identityKey":"\#(entry.identityKey.base64EncodedString())","signingKey":"\#(entry.signingKey.base64EncodedString())","mailboxId":"m","preKeyBundle":\#(String(decoding: try JSONEncoder().encode(entry.preKeyBundle!), as: UTF8.self))}"#.utf8)
        TestURLProtocol.queue = [.init(status: 200, body: dirBody), .init(status: 200, body: Data(#"{"challenge":"QQ=="}"#.utf8)), .init(status: 201, body: Data(#"{"id":"01SENT000000000000000000AB"}"#.utf8))]
        let rec = try await store.send(text: "anon", to: "TESTRCPT", anonymous: true)
        XCTAssertEqual(rec.sender, .anonymous)
        let body = try JSONSerialization.jsonObject(with: TestURLProtocol.requests[2].httpBody!) as! [String: Any]
        let opened = try NoteCrypto.open(try NoteEnvelope.fromWire(Data(base64Encoded: body["envelope"] as! String)!), recipientAccountId: "TESTRCPT", keys: recipient.keys())
        XCTAssertNil(opened.sender)
    }
    func testSendErrors() async throws {
        TestURLProtocol.queue = [.init(status: 404, body: Data(#"{"error":"not_found"}"#.utf8))]
        do { _ = try await store.send(text: "x", to: "nobody", anonymous: true); XCTFail() } catch { XCTAssertEqual(error as? NotesStoreError, .recipientNotFound) }
        TestURLProtocol.queue = [.init(status: 200, body: Data(#"{"accountId":"TESTRCPT","nickname":null,"identityKey":"AAAA","signingKey":"AAAA","mailboxId":"m"}"#.utf8))]
        do { _ = try await store.send(text: "x", to: "TESTRCPT", anonymous: true); XCTFail() } catch { XCTAssertEqual(error as? NotesStoreError, .recipientHasNoKeys) }
        do { _ = try await store.send(text: String(repeating: "x", count: 2_001), to: "TESTRCPT", anonymous: true); XCTFail() } catch { XCTAssertEqual(error as? NotesStoreError, .textTooLong) }
    }
    func testMarkReadDeleteBlockReport() async throws {
        let env = try NoteCrypto.seal(text: "hi", recipient: try me.entry(), signer: nil)
        TestURLProtocol.queue = [.init(status: 200, body: try inboxJSON([("01AAAAAAAAAAAAAAAAAAAAAAAE", env)]))]
        await store.sync()
        let rec = store.inbox[0]
        TestURLProtocol.queue = [.init(status: 204, body: Data())]
        await store.markRead(rec.id)
        XCTAssertNotNil(store.inbox[0].readAt); XCTAssertEqual(store.unreadCount, 0)
        XCTAssertEqual(TestURLProtocol.requests[1].url?.path, "/v3/inbox/01AAAAAAAAAAAAAAAAAAAAAAAE/read")
        TestURLProtocol.queue = [.init(status: 200, body: Data(#"{"blocked":"ff"}"#.utf8)), .init(status: 201, body: Data(#"{"id":"01R"}"#.utf8)), .init(status: 201, body: Data(#"{"id":"01R2"}"#.utf8))]
        let blocked = try await store.block(rec)
        XCTAssertEqual(blocked, "ff")
        try await store.report(rec, reason: .spam, includeText: true)
        let b1 = try JSONSerialization.jsonObject(with: TestURLProtocol.requests[3].httpBody!) as! [String: Any]
        XCTAssertEqual(b1["excerpt"] as? String, "hi")
        try await store.report(rec, reason: .other, includeText: false)
        let b2 = try JSONSerialization.jsonObject(with: TestURLProtocol.requests[4].httpBody!) as! [String: Any]
        XCTAssertNil(b2["excerpt"])
        TestURLProtocol.queue = [.init(status: 204, body: Data())]
        await store.delete(rec)
        XCTAssertTrue(store.inbox.isEmpty)
        XCTAssertEqual(TestURLProtocol.requests[5].httpMethod, "DELETE")
        // A fresh store over the same directory no longer sees the deleted note.
        XCTAssertTrue(NotesStorage(directory: dir, encryptor: store.storage.encryptor).loadInbox().isEmpty)
    }
    func testReportTruncatesExcerptToMaxScalars() async throws {
        let longText = String(repeating: "a", count: 1_500)
        let env = try NoteCrypto.seal(text: longText, recipient: try me.entry(), signer: nil)
        TestURLProtocol.queue = [.init(status: 200, body: try inboxJSON([("01AAAAAAAAAAAAAAAAAAAAAAAI", env)]))]
        await store.sync()
        let rec = store.inbox[0]
        TestURLProtocol.queue = [.init(status: 201, body: Data(#"{"id":"01R3"}"#.utf8))]
        try await store.report(rec, reason: .spam, includeText: true)
        let body = try JSONSerialization.jsonObject(with: TestURLProtocol.requests[1].httpBody!) as! [String: Any]
        let excerpt = body["excerpt"] as! String
        XCTAssertEqual(excerpt.unicodeScalars.count, NotesStore.maxExcerptScalars)
    }
    func testBlockOn404ThrowsNoteNotFound() async throws {
        TestURLProtocol.queue = [.init(status: 404, body: Data(#"{"error":"not_found"}"#.utf8))]
        let rec = NoteRecord(id: "01NF", direction: .inbound, text: "t", sentAt: Date(), sender: .anonymous, recipientAccountId: nil, readAt: nil, receivedAt: Date())
        do { _ = try await store.block(rec); XCTFail() } catch { XCTAssertEqual(error as? NotesStoreError, .noteNotFound) }
    }
    func testMockInitIsReadyWithoutNetwork() async throws {
        let r = NoteRecord(id: "01M", direction: .inbound, text: "mock", sentAt: Date(), sender: .anonymous, recipientAccountId: nil, readAt: nil, receivedAt: Date())
        let s = NotesStore(mockInbox: [r], sent: [])
        XCTAssertEqual(s.inbox, [r]); XCTAssertEqual(s.unreadCount, 1)
        let blocks = try await s.blocks()
        XCTAssertTrue(blocks.isEmpty)
        await s.markRead("01M")
        XCTAssertNotNil(s.inbox[0].readAt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.storage.directory.path))   // markRead never touched disk
    }
}
