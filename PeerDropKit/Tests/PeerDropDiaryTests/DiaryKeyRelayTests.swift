import XCTest
import CryptoKit
import PeerDropSecurity
import PeerDropAccount
@testable import PeerDropNotes
@testable import PeerDropDiary

final class DiaryKeyRelayTests: XCTestCase {
    private var tempDir: URL!
    private var keyStore: DiaryKeyStore!
    private var notesClient: NotesClient!
    private var crypto: DiaryFakeCrypto!
    private var recipient: DiaryRecipientFixture!
    private let diaryId = "01DIARYRELAYTEST00000000A"

    override func setUp() async throws {
        TestURLProtocol.reset()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        keyStore = DiaryKeyStore(directory: tempDir, encryptor: ChatDataEncryptor(testKey: SymmetricKey(size: .bits256)))
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [TestURLProtocol.self]
        let account = AccountClient(baseURL: URL(string: "https://worker.test")!, session: URLSession(configuration: cfg), authProvider: { _ in }, tokenInvalidator: {})
        notesClient = NotesClient(account: account)
        crypto = DiaryFakeCrypto()
        recipient = try DiaryRecipientFixture()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func metaCipher(key: SymmetricKey) throws -> String {
        try DiaryCrypto.sealMeta(name: "Diary", key: key, diaryId: diaryId, keyEpoch: 1).base64EncodedString()
    }

    private func queueSuccessfulSend() throws {
        TestURLProtocol.queue = [
            .init(status: 200, body: try recipient.directoryJSON()),           // GET /v3/directory/NEWMEMBR?bundle=1
            .init(status: 200, body: Data(#"{"challenge":"Q0hBTA=="}"#.utf8)), // GET /v3/pow/challenge
            .init(status: 201, body: Data(#"{"id":"01SENT0000000000000000000A"}"#.utf8)), // POST /v3/notes/NEWMEMBR
        ]
    }

    // MARK: - No local key / wrong key → no-op, no network

    func testNoLocalKeyIsANoOpWithNoNetworkCall() async {
        let relay = DiaryKeyRelay(notesClient: notesClient, crypto: crypto, keyStore: keyStore)
        await relay.relayIfNeeded(diaryId: diaryId, newMember: recipient.accountId.raw, metaCipher: "bWV0YQ==",
                                  senderAccountId: "SENDER01", senderNickname: "me")
        XCTAssertEqual(TestURLProtocol.requests.count, 0)
    }

    func testKeyThatDoesNotOpenMetaCipherIsANoOpWithNoNetworkCall() async throws {
        let realKey = SymmetricKey(size: .bits256)
        let wrongKey = SymmetricKey(size: .bits256)
        try keyStore.save(key: wrongKey, for: diaryId)
        let cipher = try metaCipher(key: realKey)   // sealed with a DIFFERENT key than what's saved
        let relay = DiaryKeyRelay(notesClient: notesClient, crypto: crypto, keyStore: keyStore)
        await relay.relayIfNeeded(diaryId: diaryId, newMember: recipient.accountId.raw, metaCipher: cipher,
                                  senderAccountId: "SENDER01", senderNickname: "me")
        XCTAssertEqual(TestURLProtocol.requests.count, 0)
    }

    // MARK: - Success path

    func testWorkingKeySealsAndSendsASignedDiaryKeyNote() async throws {
        let key = SymmetricKey(size: .bits256)
        try keyStore.save(key: key, for: diaryId)
        let cipher = try metaCipher(key: key)
        try queueSuccessfulSend()
        let relay = DiaryKeyRelay(notesClient: notesClient, crypto: crypto, keyStore: keyStore)

        await relay.relayIfNeeded(diaryId: diaryId, newMember: recipient.accountId.raw, metaCipher: cipher,
                                  senderAccountId: "SENDER01", senderNickname: "alice")

        XCTAssertEqual(TestURLProtocol.requests.count, 3)
        XCTAssertEqual(TestURLProtocol.requests[0].url?.path, "/v3/directory/\(recipient.accountId.raw)")
        XCTAssertEqual(TestURLProtocol.requests[0].url?.query, "bundle=1")
        XCTAssertEqual(TestURLProtocol.requests[1].url?.path, "/v3/pow/challenge")
        XCTAssertEqual(TestURLProtocol.requests[2].url?.path, "/v3/notes/\(recipient.accountId.raw)")
        let body = try JSONSerialization.jsonObject(with: TestURLProtocol.requests[2].httpBody!) as! [String: Any]
        XCTAssertEqual(body["kind"] as? String, "diaryKey")
        XCTAssertEqual(body["diaryId"] as? String, diaryId)

        // Decrypt the envelope the relay actually sent and check the inner
        // JSON payload + that it was signed (never anonymous).
        let envB64 = body["envelope"] as! String
        let envelope = try NoteEnvelope.fromWire(Data(base64Encoded: envB64)!)
        let opened = try NoteCrypto.open(envelope, recipientAccountId: recipient.accountId.raw, keys: recipient.keys())
        XCTAssertEqual(opened.kind, .diaryKey)
        XCTAssertNotNil(opened.sender)
        XCTAssertEqual(opened.sender?.accountId, "SENDER01")
        // `keyEpoch` is a JSON number, not a string, so decode via the raw
        // object rather than `[String: String]`.
        let raw = try JSONSerialization.jsonObject(with: Data(opened.text.utf8)) as! [String: Any]
        XCTAssertEqual(raw["diaryId"] as? String, diaryId)
        XCTAssertEqual(raw["keyEpoch"] as? Int, 1)
        XCTAssertEqual(Data(base64Encoded: raw["key"] as? String ?? ""), key.withUnsafeBytes { Data($0) })
        // Sorted-keys JSON, per spec §3.3: "diaryId" < "key" < "keyEpoch".
        XCTAssertTrue(opened.text.hasPrefix(#"{"diaryId""#))
    }

    // MARK: - Dedupe: 24h window after a real success

    func testSecondCallWithinTwentyFourHoursDoesNotSendAgain() async throws {
        let key = SymmetricKey(size: .bits256)
        try keyStore.save(key: key, for: diaryId)
        let cipher = try metaCipher(key: key)
        var now = Date()
        let relay = DiaryKeyRelay(notesClient: notesClient, crypto: crypto, keyStore: keyStore, now: { now })

        try queueSuccessfulSend()
        await relay.relayIfNeeded(diaryId: diaryId, newMember: recipient.accountId.raw, metaCipher: cipher, senderAccountId: "SENDER01", senderNickname: nil)
        XCTAssertEqual(TestURLProtocol.requests.count, 3)

        now = now.addingTimeInterval(3_600)   // 1h later — still inside the 24h window
        await relay.relayIfNeeded(diaryId: diaryId, newMember: recipient.accountId.raw, metaCipher: cipher, senderAccountId: "SENDER01", senderNickname: nil)
        XCTAssertEqual(TestURLProtocol.requests.count, 3)   // no new requests
    }

    func testCallAfterTwentyFourHoursSendsAgain() async throws {
        let key = SymmetricKey(size: .bits256)
        try keyStore.save(key: key, for: diaryId)
        let cipher = try metaCipher(key: key)
        var now = Date()
        let relay = DiaryKeyRelay(notesClient: notesClient, crypto: crypto, keyStore: keyStore, now: { now })

        try queueSuccessfulSend()
        await relay.relayIfNeeded(diaryId: diaryId, newMember: recipient.accountId.raw, metaCipher: cipher, senderAccountId: "SENDER01", senderNickname: nil)
        XCTAssertEqual(TestURLProtocol.requests.count, 3)

        now = now.addingTimeInterval(86_401)
        try queueSuccessfulSend()
        await relay.relayIfNeeded(diaryId: diaryId, newMember: recipient.accountId.raw, metaCipher: cipher, senderAccountId: "SENDER01", senderNickname: nil)
        XCTAssertEqual(TestURLProtocol.requests.count, 6)
    }

    // MARK: - force bypasses the dedupe

    func testForceBypassesTheDedupeEvenSecondsLater() async throws {
        let key = SymmetricKey(size: .bits256)
        try keyStore.save(key: key, for: diaryId)
        let cipher = try metaCipher(key: key)
        let relay = DiaryKeyRelay(notesClient: notesClient, crypto: crypto, keyStore: keyStore)

        try queueSuccessfulSend()
        await relay.relayIfNeeded(diaryId: diaryId, newMember: recipient.accountId.raw, metaCipher: cipher, senderAccountId: "SENDER01", senderNickname: nil)
        XCTAssertEqual(TestURLProtocol.requests.count, 3)

        try queueSuccessfulSend()
        await relay.relayIfNeeded(diaryId: diaryId, newMember: recipient.accountId.raw, metaCipher: cipher, senderAccountId: "SENDER01", senderNickname: nil, force: true)
        XCTAssertEqual(TestURLProtocol.requests.count, 6)
    }

    // MARK: - A blocked/failed send never dedupes — "封鎖造成的假 201 不會出現"

    func testA403FromTheWorkerIsNotDedupedAndRetriesOnTheNextCall() async throws {
        let key = SymmetricKey(size: .bits256)
        try keyStore.save(key: key, for: diaryId)
        let cipher = try metaCipher(key: key)
        let relay = DiaryKeyRelay(notesClient: notesClient, crypto: crypto, keyStore: keyStore)

        TestURLProtocol.queue = [
            .init(status: 200, body: try recipient.directoryJSON()),
            .init(status: 200, body: Data(#"{"challenge":"Q0hBTA=="}"#.utf8)),
            .init(status: 403, body: Data(#"{"error":"not_member"}"#.utf8)),
        ]
        await relay.relayIfNeeded(diaryId: diaryId, newMember: recipient.accountId.raw, metaCipher: cipher, senderAccountId: "SENDER01", senderNickname: nil)
        XCTAssertEqual(TestURLProtocol.requests.count, 3)

        // No dedupe was written — the very next call (still well within what
        // would have been the 24h window) tries again from scratch.
        try queueSuccessfulSend()
        await relay.relayIfNeeded(diaryId: diaryId, newMember: recipient.accountId.raw, metaCipher: cipher, senderAccountId: "SENDER01", senderNickname: nil)
        XCTAssertEqual(TestURLProtocol.requests.count, 6)
    }
}
