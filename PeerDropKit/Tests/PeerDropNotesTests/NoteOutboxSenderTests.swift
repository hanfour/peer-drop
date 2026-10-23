import XCTest
import CryptoKit
import PeerDropSecurity
import PeerDropAccount
@testable import PeerDropNotes

@MainActor
final class NoteOutboxSenderTests: XCTestCase {
    private var dir: URL!
    private var store: NoteOutboxStore!
    private let contact = UUID()
    private let acct = "TESTRCPT"
    private let key = Data(repeating: 7, count: 32)
    private var now = Date(timeIntervalSince1970: 1_000_000)
    private var sent: [String] = []
    private var results: [Result<Void, Error>] = []
    private var lookup: OutboxBindingLookup = .verified(accountId: "TESTRCPT")
    private var delay: UInt64 = 0

    override func setUp() { reset() }
    private func reset() {
        sent = []; results = []; lookup = .verified(accountId: "TESTRCPT")
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-s-\(UUID().uuidString)", isDirectory: true)
        store = NoteOutboxStore(directory: dir, encryptor: ChatDataEncryptor(testKey: SymmetricKey(size: .bits256)))
        TestURLProtocol.reset()
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func record() -> NoteRecord {
        NoteRecord(id: UUID().uuidString, direction: .outbound, text: "t", sentAt: now, sender: .anonymous, recipientAccountId: acct, readAt: nil, receivedAt: now)
    }
    private func makeSender() -> NoteOutboxSender {
        NoteOutboxSender(store: store, send: { [unowned self] text, _, _ in
            self.sent.append(text)
            if self.delay > 0 { try await Task.sleep(nanoseconds: self.delay) }
            if !self.results.isEmpty, case .failure(let e) = self.results.removeFirst() { throw e }
            return self.record()
        }, binding: { [unowned self] _ in self.lookup }, baseDelay: 30, clock: { [unowned self] in self.now })
    }
    @discardableResult private func queue(_ text: String = "hello") -> NoteOutboxEntry {
        store.enqueue(contactID: contact, accountId: acct, expectedIdentityKey: key, text: text, now: now)
    }

    func testSuccessRemovesEntry() async {
        queue(); results = [.success(())]
        await makeSender().flush(now: now)
        XCTAssertTrue(store.all.isEmpty); XCTAssertEqual(sent, ["hello"])
    }

    func testRetryableErrorBacksOffAndFailsAfterThree() async {
        let e = queue(); let s = makeSender()
        results = [.failure(NotesStoreError.network("x")), .failure(NotesStoreError.rateLimited), .failure(NotesStoreError.opkExhausted)]
        await s.flush()
        XCTAssertEqual(store.all[0].attempts, 1); XCTAssertEqual(store.all[0].state, .queued)
        XCTAssertEqual(store.all[0].nextAttemptAt, now.addingTimeInterval(30))
        await s.flush()                     // before nextAttemptAt: nothing sent
        XCTAssertEqual(sent.count, 1)
        now = now.addingTimeInterval(31); await s.flush()
        XCTAssertEqual(store.all[0].attempts, 2); XCTAssertEqual(store.all[0].nextAttemptAt, now.addingTimeInterval(120))
        now = now.addingTimeInterval(121); await s.flush()
        XCTAssertEqual(store.all[0].state, .failed); XCTAssertEqual(store.all[0].attempts, 3)
        XCTAssertNotNil(store.all[0].failReason); XCTAssertEqual(store.all[0].id, e.id)
        now = now.addingTimeInterval(10_000); await s.flush()
        XCTAssertEqual(sent.count, 3)       // failed entries are never auto-sent
    }

    func testURLErrorIsRetryable() async {
        queue(); results = [.failure(URLError(.notConnectedToInternet))]
        await makeSender().flush()
        XCTAssertEqual(store.all[0].attempts, 1); XCTAssertEqual(store.all[0].state, .queued)
    }

    func testExpiresAfter24Hours() async {
        queue(); now = now.addingTimeInterval(24 * 3600 + 1)
        await makeSender().flush()
        XCTAssertEqual(store.all[0].state, .failed); XCTAssertTrue(sent.isEmpty)
    }

    func testRetryableErrorPast24HoursFailsInsteadOfBackoff() async {
        queue(); now = now.addingTimeInterval(24 * 3600 - 1)
        results = [.failure(NotesStoreError.network("x"))]
        // make the clock cross the limit during the send
        let slow = NoteOutboxSender(store: store, send: { [unowned self] _, _, _ in
            self.now = self.now.addingTimeInterval(10); throw NotesStoreError.network("x")
        }, binding: { [unowned self] _ in self.lookup }, clock: { [unowned self] in self.now })
        await slow.flush()
        XCTAssertEqual(store.all[0].state, .failed)
    }

    func testTerminalErrorsFailImmediatelyWithReason() async {
        let cases: [(NotesStoreError, String?)] = [
            (.recipientNotFound, nil), (.recipientHasNoKeys, nil), (.textTooLong, nil), (.recipientMismatch, "重新交換")]
        for (err, hint) in cases {
            reset(); queue(); results = [.failure(err)]
            await makeSender().flush()
            XCTAssertEqual(store.all[0].state, .failed, "\(err)")
            XCTAssertEqual(store.all[0].attempts, 0)
            XCTAssertFalse((store.all[0].failReason ?? "").isEmpty)
            if let hint { XCTAssertTrue(store.all[0].failReason!.contains(hint)) }
        }
    }

    func testNoAccountWaitsWithoutAttempt() async {
        queue(); results = [.failure(NotesStoreError.noAccount)]
        let s = makeSender()
        await s.flush()
        XCTAssertEqual(store.all[0].state, .queued); XCTAssertEqual(store.all[0].attempts, 0); XCTAssertNil(store.all[0].nextAttemptAt)
        await s.flush()   // account ready now
        XCTAssertTrue(store.all.isEmpty)
    }

    func testBindingClearedOrChangedFailsWithoutNetwork() async {
        queue(); lookup = .none
        await makeSender().flush()
        XCTAssertEqual(store.all[0].state, .failed); XCTAssertEqual(store.all[0].failReason, "綁定已取消")
        XCTAssertTrue(sent.isEmpty)
        reset(); queue(); lookup = .verified(accountId: "OTHR2345")
        await makeSender().flush()
        XCTAssertEqual(store.all[0].failReason, "綁定已取消"); XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(store.all.count, 1)  // never auto-deleted
    }

    func testPendingBindingWaits() async {
        queue(); lookup = .pending
        await makeSender().flush()
        XCTAssertEqual(store.all[0].state, .queued); XCTAssertTrue(sent.isEmpty)
    }

    func testManualRetryResetsAttempts() async {
        let e = queue(); let s = makeSender()
        results = [.failure(NotesStoreError.textTooLong)]
        await s.flush()
        XCTAssertEqual(store.all[0].state, .failed)
        store.retry(id: e.id, now: now)
        XCTAssertEqual(store.all[0].attempts, 0)
        await s.flush()
        XCTAssertTrue(store.all.isEmpty); XCTAssertEqual(sent.count, 2)
    }

    func testSingleFlightDoesNotDoubleSend() async {
        queue(); delay = 50_000_000
        let s = makeSender()
        async let a: Void = s.flush(); async let b: Void = s.flush()
        _ = await (a, b)
        XCTAssertEqual(sent.count, 1)
        XCTAssertTrue(store.all.isEmpty)
    }

    func testNeverSendsUnqueuedText() async {
        let s = makeSender()
        await s.flush()
        XCTAssertTrue(sent.isEmpty)
        queue("only-this")
        await s.flush()
        XCTAssertEqual(sent, ["only-this"])
    }

    func testDuplicateRiskIsDocumentedAndBounded() async {
        // The POST "reached the server" but the client saw a network error every time:
        // we retry (accepting a possible duplicate) but never forever.
        queue(); results = Array(repeating: .failure(NotesStoreError.network("response lost")), count: 50)
        let s = makeSender()
        for _ in 0..<10 { now = now.addingTimeInterval(1000); await s.flush() }
        XCTAssertEqual(sent.count, NoteOutboxSender.maxAttempts)
        XCTAssertEqual(store.all[0].state, .failed)
    }

    // MARK: against the real NotesStore

    private struct Crypto: NotesCryptoContext {
        let fixture: RecipientFixture
        let signing = Curve25519.Signing.PrivateKey()
        func recipientKeys() throws -> NoteRecipientKeys { fixture.keys() }
        func signer(accountId: String, nickname: String?) throws -> NoteSigner {
            NoteSigner(accountId: accountId, nickname: nickname, signingPublicKey: signing.publicKey.rawRepresentation, sign: { try self.signing.signature(for: $0) })
        }
    }
    private func realStore() throws -> NotesStore {
        let me = try RecipientFixture()
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [TestURLProtocol.self]
        let account = AccountClient(baseURL: URL(string: "https://worker.test")!, session: URLSession(configuration: cfg), authProvider: { _ in }, tokenInvalidator: {})
        let manager = AccountManager(mock: Account(accountId: me.accountId, nickname: "me", mailboxId: "mbx", createdAt: Date()))
        return NotesStore(client: NotesClient(account: account), accountManager: manager, crypto: Crypto(fixture: me),
                          storage: NotesStorage(directory: dir.appendingPathComponent("n"), encryptor: ChatDataEncryptor(testKey: SymmetricKey(size: .bits256))))
    }
    private func directoryBody(_ entry: DirectoryEntry) throws -> Data {
        Data(#"{"accountId":"TESTRCPT","nickname":"bob","identityKey":"\#(entry.identityKey.base64EncodedString())","signingKey":"\#(entry.signingKey.base64EncodedString())","mailboxId":"m","preKeyBundle":\#(String(decoding: try JSONEncoder().encode(entry.preKeyBundle!), as: UTF8.self))}"#.utf8)
    }

    func testRealStoreSuccessRemovesEntryAndKeepsSentNote() async throws {
        let ns = try realStore(); let entry = try RecipientFixture().entry()
        TestURLProtocol.queue = [.init(status: 200, body: try directoryBody(entry)),
                                 .init(status: 200, body: Data(#"{"challenge":"Q0hBTA=="}"#.utf8)),
                                 .init(status: 201, body: Data(#"{"id":"01OUTBOX00000000000000AA"}"#.utf8))]
        store.enqueue(contactID: contact, accountId: acct, expectedIdentityKey: entry.identityKey, text: "real", now: Date())
        let s = NoteOutboxSender(store: store, notesStore: ns, binding: { [unowned self] _ in self.lookup })
        await s.flush()
        XCTAssertTrue(store.all.isEmpty)
        XCTAssertEqual(ns.sent.first?.text, "real")
    }

    func testRealStoreRecipientMismatchIsPermanentAndNotRetried() async throws {
        let ns = try realStore(); let entry = try RecipientFixture().entry()
        TestURLProtocol.queue = [.init(status: 200, body: try directoryBody(entry))]
        store.enqueue(contactID: contact, accountId: acct, expectedIdentityKey: Data(repeating: 9, count: 32), text: "x", now: Date())
        let s = NoteOutboxSender(store: store, notesStore: ns, binding: { [unowned self] _ in self.lookup })
        await s.flush(); await s.flush()
        XCTAssertEqual(store.all[0].state, .failed)
        XCTAssertTrue(store.all[0].failReason!.contains("重新交換"))
        XCTAssertEqual(TestURLProtocol.requests.count, 1)
        XCTAssertTrue(ns.sent.isEmpty)
    }
}
