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
    func testKeyMismatchStaysUnverifiedWithoutFurtherLookups() async throws {
        let sender = SenderFixture()
        let env = try NoteCrypto.seal(text: "s", recipient: try me.entry(), signer: sender.signer)
        let id = "01AAAAAAAAAAAAAAAAAAAAAAAY"
        TestURLProtocol.queue = [.init(status: 200, body: try inboxJSON([(id, env)])), .init(status: 200, body: directoryJSON(signingKey: Data(repeating: 9, count: 32)))]
        await store.sync()
        XCTAssertEqual(store.inbox[0].sender, .unverified(accountId: "SENDR001"))
        let requestsAfterFirstSync = TestURLProtocol.requests.count
        // Second sync: no directory stub queued — if the mismatch were
        // retried it would consume the default 500 and stay unverified
        // anyway, so assert on the request COUNT to prove no lookup ran.
        TestURLProtocol.queue = [.init(status: 200, body: try inboxJSON([(id, env)]))]
        await store.sync()
        XCTAssertEqual(store.inbox[0].sender, .unverified(accountId: "SENDR001"))
        XCTAssertEqual(TestURLProtocol.requests.count, requestsAfterFirstSync + 1)   // only the inbox page; no directory call
    }
    func testUndecryptableItemIsKeptWithNilText() async throws {
        let junk = NoteEnvelope(v: 1, ephemeralKey: Data(repeating: 1, count: 32), ephemeralKey2: Data(repeating: 2, count: 32), spkId: 99, opkId: nil, nonce: Data(count: 12), ciphertext: Data(count: 32))
        TestURLProtocol.queue = [.init(status: 200, body: try inboxJSON([("01AAAAAAAAAAAAAAAAAAAAAAAD", junk)]))]
        await store.sync()
        XCTAssertEqual(store.inbox.count, 1)
        XCTAssertNil(store.inbox[0].text)
        XCTAssertTrue(store.inbox[0].isUndecryptable)
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
