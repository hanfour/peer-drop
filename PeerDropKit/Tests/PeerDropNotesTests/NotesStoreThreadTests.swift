import XCTest
import CryptoKit
import PeerDropSecurity
import PeerDropAccount
@testable import PeerDropNotes

@MainActor
final class NotesStoreThreadTests: XCTestCase {
    private var me: RecipientFixture!
    private var store: NotesStore!
    private var dir: URL!
    private let friend = "FRND2345"

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
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("notes-thread-\(UUID().uuidString)", isDirectory: true)
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [TestURLProtocol.self]
        let account = AccountClient(baseURL: URL(string: "https://worker.test")!, session: URLSession(configuration: cfg), authProvider: { _ in }, tokenInvalidator: {})
        let manager = AccountManager(mock: Account(accountId: me.accountId, nickname: "rcpt", mailboxId: "mbxtest", createdAt: Date()))
        store = NotesStore(client: NotesClient(account: account), accountManager: manager, crypto: FakeCrypto(fixture: me),
                           storage: NotesStorage(directory: dir, encryptor: ChatDataEncryptor(testKey: SymmetricKey(size: .bits256))))
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func inbound(_ id: String, sender: NoteSenderState, text: String? = "hi", read: Bool = false, at: TimeInterval) -> NoteRecord {
        NoteRecord(id: id, direction: .inbound, text: text, sentAt: Date(timeIntervalSince1970: at), sender: sender,
                   recipientAccountId: nil, readAt: read ? Date() : nil, receivedAt: Date(timeIntervalSince1970: at))
    }
    private func outbound(_ id: String, to: String?, anonymous: Bool, at: TimeInterval) -> NoteRecord {
        NoteRecord(id: id, direction: .outbound, text: "out", sentAt: Date(timeIntervalSince1970: at),
                   sender: anonymous ? .anonymous : .verified(accountId: "TESTRCPT", nickname: "rcpt"),
                   recipientAccountId: to, readAt: nil, receivedAt: Date(timeIntervalSince1970: at))
    }
    private func seed(_ inbox: [NoteRecord], _ sent: [NoteRecord]) throws {
        for r in inbox + sent { try store.storage.save(r) }
        store.load()
    }

    // MARK: queries

    func testNotesForAccountAttribution() throws {
        try seed([
            inbound("in-verified", sender: .verified(accountId: friend, nickname: "f"), at: 100),
            inbound("in-other", sender: .verified(accountId: "OTHR2345", nickname: nil), at: 101),
            inbound("in-unverified", sender: .unverified(accountId: friend), at: 102),
            inbound("in-anon", sender: .anonymous, at: 103),
            inbound("in-undecryptable", sender: .anonymous, text: nil, at: 104),
        ], [
            outbound("out-signed", to: friend, anonymous: false, at: 200),
            outbound("out-anon", to: friend, anonymous: true, at: 201),
            outbound("out-other", to: "OTHR2345", anonymous: false, at: 202),
        ])
        let ids = Set(store.notes(forAccount: friend).map(\.id))
        XCTAssertEqual(ids, ["in-verified", "out-signed"])
    }

    func testNotesForAccountSortedOldestFirst() throws {
        try seed([inbound("b", sender: .verified(accountId: friend, nickname: nil), at: 300)],
                 [outbound("a", to: friend, anonymous: false, at: 100), outbound("c", to: friend, anonymous: false, at: 500)])
        XCTAssertEqual(store.notes(forAccount: friend).map(\.id), ["a", "b", "c"])
    }

    func testUnreadCountOnlyVerifiedAccountNotes() throws {
        try seed([
            inbound("u1", sender: .verified(accountId: friend, nickname: nil), at: 100),
            inbound("r1", sender: .verified(accountId: friend, nickname: nil), read: true, at: 101),
            inbound("o1", sender: .verified(accountId: "OTHR2345", nickname: nil), at: 102),
            inbound("x1", sender: .unverified(accountId: friend), at: 103),
            inbound("a1", sender: .anonymous, at: 104),
            inbound("d1", sender: .anonymous, text: nil, at: 105),
        ], [outbound("s1", to: friend, anonymous: false, at: 106)])
        XCTAssertEqual(store.unreadCount(forAccount: friend), 1)
        XCTAssertEqual(store.unreadCount(forAccount: "NONE2345"), 0)
    }

    func testBoundUnreadIDs() throws {
        try seed([
            inbound("u1", sender: .verified(accountId: friend, nickname: nil), at: 100),
            inbound("u2", sender: .verified(accountId: "OTHR2345", nickname: nil), at: 101),
            inbound("r1", sender: .verified(accountId: friend, nickname: nil), read: true, at: 102),
            inbound("a1", sender: .anonymous, at: 103),
        ], [])
        XCTAssertEqual(store.boundUnreadIDs(accounts: [friend, "OTHR2345"]), ["u1", "u2"])
        XCTAssertEqual(store.boundUnreadIDs(accounts: [friend]), ["u1"])
    }

    // MARK: sendToBound

    private func directoryBody(_ accountId: String, entry: DirectoryEntry, identityKey: Data? = nil) throws -> Data {
        Data(#"{"accountId":"\#(accountId)","nickname":"bob","identityKey":"\#((identityKey ?? entry.identityKey).base64EncodedString())","signingKey":"\#(entry.signingKey.base64EncodedString())","mailboxId":"m","preKeyBundle":\#(String(decoding: try JSONEncoder().encode(entry.preKeyBundle!), as: UTF8.self))}"#.utf8)
    }

    func testSendToBoundSuccessStoresSignedOutboundRecord() async throws {
        let recipient = try RecipientFixture(); let entry = try recipient.entry()
        TestURLProtocol.queue = [.init(status: 200, body: try directoryBody("TESTRCPT", entry: entry)),
                                 .init(status: 200, body: Data(#"{"challenge":"Q0hBTA=="}"#.utf8)),
                                 .init(status: 201, body: Data(#"{"id":"01BOUND0000000000000000AA"}"#.utf8))]
        let rec = try await store.sendToBound(text: "hello", accountId: "TESTRCPT", expectedIdentityKey: entry.identityKey)
        XCTAssertEqual(rec.direction, .outbound)
        XCTAssertEqual(rec.sender, .verified(accountId: "TESTRCPT", nickname: "rcpt"))
        XCTAssertEqual(rec.recipientAccountId, "TESTRCPT")
        XCTAssertEqual(store.sent.map(\.id), [rec.id])
        XCTAssertEqual(store.notes(forAccount: "TESTRCPT").map(\.id), [rec.id])
        let body = try JSONSerialization.jsonObject(with: TestURLProtocol.requests[2].httpBody!) as! [String: Any]
        let opened = try NoteCrypto.open(try NoteEnvelope.fromWire(Data(base64Encoded: body["envelope"] as! String)!), recipientAccountId: "TESTRCPT", keys: recipient.keys())
        XCTAssertEqual(opened.sender?.accountId, me.accountId.raw)
        XCTAssertEqual(rec.sender, .verified(accountId: me.accountId.raw, nickname: "rcpt"))
    }

    func testSendToBoundNicknameCollisionThrowsBeforeSealing() async throws {
        // Directory resolved "ABCD1234" as a nickname of another account.
        let recipient = try RecipientFixture(); let entry = try recipient.entry()   // accountId TESTRCPT
        TestURLProtocol.queue = [.init(status: 200, body: try directoryBody("TESTRCPT", entry: entry))]
        do {
            _ = try await store.sendToBound(text: "x", accountId: "ABCD1234", expectedIdentityKey: entry.identityKey)
            XCTFail("expected mismatch")
        } catch { XCTAssertEqual(error as? NotesStoreError, .recipientMismatch) }
        XCTAssertEqual(TestURLProtocol.requests.count, 1)   // no pow, no send
        XCTAssertTrue(store.sent.isEmpty)
    }

    func testSendToBoundIdentityKeyMismatchThrows() async throws {
        let recipient = try RecipientFixture(); let entry = try recipient.entry()
        TestURLProtocol.queue = [.init(status: 200, body: try directoryBody("TESTRCPT", entry: entry))]
        do {
            _ = try await store.sendToBound(text: "x", accountId: "TESTRCPT", expectedIdentityKey: Data(repeating: 9, count: 32))
            XCTFail("expected mismatch")
        } catch { XCTAssertEqual(error as? NotesStoreError, .recipientMismatch) }
        XCTAssertEqual(TestURLProtocol.requests.count, 1)
        XCTAssertTrue(store.sent.isEmpty)
    }

    func testSendToBoundNotFound() async throws {
        TestURLProtocol.queue = [.init(status: 404, body: Data(#"{"error":"not_found"}"#.utf8))]
        do { _ = try await store.sendToBound(text: "x", accountId: "TESTRCPT", expectedIdentityKey: Data(repeating: 1, count: 32)); XCTFail() }
        catch { XCTAssertEqual(error as? NotesStoreError, .recipientNotFound) }
    }

    func testNotesForAccountTieBreaksByIdWhenTimestampsEqual() throws {
        try seed([inbound("z", sender: .verified(accountId: friend, nickname: nil), at: 100),
                  inbound("a", sender: .verified(accountId: friend, nickname: nil), at: 100)],
                 [outbound("m", to: friend, anonymous: false, at: 100)])
        XCTAssertEqual(store.notes(forAccount: friend).map(\.id), ["a", "m", "z"])
    }

    func testSendToBoundNonNormalisedAccountIdFailsClosed() async throws {
        let recipient = try RecipientFixture(); let entry = try recipient.entry()   // raw TESTRCPT
        TestURLProtocol.queue = [.init(status: 200, body: try directoryBody("TESTRCPT", entry: entry))]
        do { _ = try await store.sendToBound(text: "x", accountId: "testrcpt", expectedIdentityKey: entry.identityKey); XCTFail() }
        catch { XCTAssertEqual(error as? NotesStoreError, .recipientMismatch) }
        XCTAssertEqual(TestURLProtocol.requests.count, 1)
    }

    func testSendToBoundMatchWithoutBundleThrowsNoKeys() async throws {
        let recipient = try RecipientFixture(); let entry = try recipient.entry()
        let body = Data(#"{"accountId":"TESTRCPT","nickname":"bob","identityKey":"\#(entry.identityKey.base64EncodedString())","signingKey":"\#(entry.signingKey.base64EncodedString())","mailboxId":"m"}"#.utf8)
        TestURLProtocol.queue = [.init(status: 200, body: body)]
        do { _ = try await store.sendToBound(text: "x", accountId: "TESTRCPT", expectedIdentityKey: entry.identityKey); XCTFail() }
        catch { XCTAssertEqual(error as? NotesStoreError, .recipientHasNoKeys) }
    }

    func testSendToBoundWithoutAccountThrowsNoAccount() async throws {
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [TestURLProtocol.self]
        let ac = AccountClient(baseURL: URL(string: "https://worker.test")!, session: URLSession(configuration: cfg), authProvider: { _ in }, tokenInvalidator: {})
        struct Deps: AccountRegistrationDependencies {
            var deviceId: String { "d" }; var platform: String { "ios" }
            var registrationSupported: Bool { true }; var attestSupported: Bool { true }
            func identityKeys() throws -> (identity: Data, signing: Data) { (Data(), Data()) }
            func sign(_ data: Data) throws -> Data { Data() }
            func currentMailbox() async throws -> (id: String, token: String) { ("", "") }
        }
        let idle = AccountManager(client: ac, store: AccountStore(storageKey: "idle", directory: dir.appendingPathComponent("acct"), encryptor: ChatDataEncryptor(testKey: SymmetricKey(size: .bits256))),
                                  deps: Deps(), tokenAdopter: { _, _ in }, tokenIsFresh: { true })
        let s2 = NotesStore(client: NotesClient(account: ac), accountManager: idle, crypto: FakeCrypto(fixture: me),
                            storage: NotesStorage(directory: dir.appendingPathComponent("y"), encryptor: ChatDataEncryptor(testKey: SymmetricKey(size: .bits256))))
        do { _ = try await s2.sendToBound(text: "x", accountId: "TESTRCPT", expectedIdentityKey: Data()); XCTFail() }
        catch { XCTAssertEqual(error as? NotesStoreError, .noAccount) }
    }
}
