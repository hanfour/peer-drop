import Foundation
import os
import PeerDropSecurity
import PeerDropAccount

/// The device's private key material for notes, injected so the store can
/// be tested without keychain/PreKeyStore. Production: `LiveNotesCryptoContext`
/// in PeerDropCore (IdentityKeyManager.shared + ConnectionManager.preKeyStore).
public protocol NotesCryptoContext: Sendable {
    func recipientKeys() throws -> NoteRecipientKeys
    func signer(accountId: String, nickname: String?) throws -> NoteSigner
}

public enum NotesStoreError: Error, Equatable {
    case noAccount
    case recipientNotFound
    case recipientHasNoKeys
    case textTooLong
    case proofOfWorkFailed
    case opkExhausted
    case rateLimited
    case inboxFull
    case network(String)
}

@MainActor
public final class NotesStore: ObservableObject {
    private static let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "NotesStore")

    @Published public private(set) var inbox: [NoteRecord] = []     // newest first
    @Published public private(set) var sent: [NoteRecord] = []      // newest first
    @Published public private(set) var unreadCount = 0
    @Published public private(set) var lastError: String?
    @Published public private(set) var isSyncing = false

    private let client: NotesClient
    private let accountManager: AccountManager
    private let crypto: NotesCryptoContext
    public let storage: NotesStorage
    private let directoryCache: DirectoryCache
    private let policy: SecurityPolicy
    private let isMock: Bool

    public init(client: NotesClient, accountManager: AccountManager, crypto: NotesCryptoContext, storage: NotesStorage,
                directoryCache: DirectoryCache = DirectoryCache(), policy: SecurityPolicy = .bundledDefault) {
        self.client = client; self.accountManager = accountManager; self.crypto = crypto
        self.storage = storage; self.directoryCache = directoryCache; self.policy = policy; self.isMock = false
        load()
    }

    private struct NoopCrypto: NotesCryptoContext {
        func recipientKeys() throws -> NoteRecipientKeys { throw NotesStoreError.noAccount }
        func signer(accountId: String, nickname: String?) throws -> NoteSigner { throw NotesStoreError.noAccount }
    }

    /// Screenshot mode: fixed content, no network, no disk.
    public init(mockInbox: [NoteRecord], sent: [NoteRecord]) {
        self.client = NotesClient(account: AccountClient(baseURL: URL(string: "https://screenshot.invalid")!))
        self.accountManager = AccountManager(mock: Account(accountId: AccountID(raw: "PDRPDEM0")!, nickname: nil, mailboxId: "screenshot", createdAt: Date()))
        self.crypto = NoopCrypto()
        self.storage = NotesStorage(directory: FileManager.default.temporaryDirectory.appendingPathComponent("NotesStore-mock-\(UUID().uuidString)", isDirectory: true))
        self.directoryCache = DirectoryCache(); self.policy = .bundledDefault; self.isMock = true
        self.inbox = mockInbox.sorted { $0.sentAt > $1.sentAt }
        self.sent = sent.sorted { $0.sentAt > $1.sentAt }
        recount()
    }

    public func note(id: String) -> NoteRecord? { inbox.first { $0.id == id } ?? sent.first { $0.id == id } }

    public func load() {
        inbox = storage.loadInbox().sorted { $0.sentAt > $1.sentAt }
        if let e = storage.lastLoadError { lastError = e }
        sent = storage.loadSent().sorted { $0.sentAt > $1.sentAt }
        if let e = storage.lastLoadError { lastError = e }
        recount()
    }

    private func recount() { unreadCount = inbox.filter(\.isUnread).count }

    // MARK: - Sync

    public func sync() async {
        guard !isMock, !isSyncing, let account = accountManager.account else { return }
        isSyncing = true
        // Always run, on every exit path (normal completion, mid-page network
        // failure, or the early `return` below): a page-2 failure must not
        // leave newly appended records unsorted with a stale unread count.
        defer {
            isSyncing = false
            inbox.sort { $0.sentAt > $1.sentAt }
            recount()
        }

        // Hoisted above the loop: a transient key-access failure aborts the
        // sync WITHOUT advancing the cursor or writing any tombstones — vs.
        // an envelope that fails to decrypt with valid keys, which still
        // yields a `text: nil` record via `decode`'s own fallback below.
        let keys: NoteRecipientKeys
        do {
            keys = try crypto.recipientKeys()
        } catch {
            lastError = String(describing: Self.mapNetwork(error))
            return
        }

        // The persisted cursor only ever advances past records that actually
        // saved — `lastPersistedId` tracks that high-water mark separately
        // from `after` (the server-controlled paging cursor), and is only
        // written back when it has moved.
        let initialCursor = storage.lastSeenInboxId
        var after = initialCursor
        var lastPersistedId = initialCursor
        var known = Set(inbox.map(\.id))
        do {
            while true {
                let page = try await client.inbox(after: after, limit: 50)
                for item in page.items {
                    // Defensive monotonic guard against a misbehaving/replayed
                    // page: every item must sort after the cursor we requested.
                    if let last = after, item.id <= last { continue }
                    guard !known.contains(item.id) else { continue }
                    let record = await decode(item, account: account, keys: keys)
                    do {
                        try storage.save(record)
                        lastPersistedId = item.id
                    } catch {
                        lastError = error.localizedDescription
                        inbox.append(record); known.insert(item.id)
                        if lastPersistedId != initialCursor { storage.lastSeenInboxId = lastPersistedId }
                        return
                    }
                    inbox.append(record); known.insert(item.id)
                }
                // Paging terminates on server-controlled input: `nextAfter`
                // is the next request cursor. Stop when the server says
                // there's no more (`nil`) or hands back the same cursor
                // again (would otherwise loop forever).
                guard let next = page.nextAfter, next != after else { break }
                after = next
            }
            lastError = nil
        } catch {
            lastError = String(describing: Self.mapNetwork(error))
            Self.logger.error("inbox sync failed: \(String(describing: error), privacy: .public)")
        }
        if lastPersistedId != initialCursor { storage.lastSeenInboxId = lastPersistedId }
    }

    private func decode(_ item: InboxItemDTO, account: Account, keys: NoteRecipientKeys) async -> NoteRecord {
        let receivedAt = Date(timeIntervalSince1970: TimeInterval(item.createdAt) / 1000)
        let readAt = item.readAt.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
        guard let bytes = Data(base64Encoded: item.envelope), let envelope = try? NoteEnvelope.fromWire(bytes),
              let plaintext = try? NoteCrypto.open(envelope, recipientAccountId: account.accountId.raw, keys: keys)
        else {
            return NoteRecord(id: item.id, direction: .inbound, text: nil, sentAt: receivedAt, sender: .anonymous, recipientAccountId: nil, readAt: readAt, receivedAt: receivedAt)
        }
        var sender: NoteSenderState = .anonymous
        if let block = plaintext.sender {
            sender = .unverified(accountId: block.accountId)
            if let entry = await directoryEntry(for: block.accountId),
               NoteCrypto.verifySender(plaintext, recipientAccountId: account.accountId.raw, directorySigningKey: entry.signingKey) {
                sender = .verified(accountId: block.accountId, nickname: entry.nickname)
            }
        }
        return NoteRecord(id: item.id, direction: .inbound, text: plaintext.text, sentAt: Date(timeIntervalSince1970: TimeInterval(plaintext.sentAt)),
                          sender: sender, recipientAccountId: nil, readAt: readAt, receivedAt: receivedAt)
    }

    private func directoryEntry(for accountId: String) async -> DirectoryCache.Entry? {
        if let cached = directoryCache.get(accountId) { return cached }
        guard let entry = try? await client.lookup(handle: accountId, includeBundle: false) else { return nil }
        directoryCache.set(accountId, signingKey: entry.signingKey, nickname: entry.nickname)
        return directoryCache.get(accountId)
    }

    // MARK: - Send

    public func send(text: String, to handle: String, anonymous: Bool) async throws -> NoteRecord {
        guard let account = accountManager.account else { throw NotesStoreError.noAccount }
        guard text.unicodeScalars.count <= NoteCrypto.maxTextScalars else { throw NotesStoreError.textTooLong }
        let entry: DirectoryEntry?
        do { entry = try await client.lookup(handle: handle, includeBundle: true) } catch { throw Self.mapNetwork(error) }
        guard let entry else { throw NotesStoreError.recipientNotFound }
        guard entry.preKeyBundle != nil else { throw NotesStoreError.recipientHasNoKeys }
        let signer = anonymous ? nil : try crypto.signer(accountId: account.accountId.raw, nickname: account.nickname)
        let envelope: NoteEnvelope
        do { envelope = try NoteCrypto.seal(text: text, recipient: entry, signer: signer, policy: policy) }
        catch NoteCryptoError.opkExhausted { throw NotesStoreError.opkExhausted }
        catch NoteCryptoError.textTooLong { throw NotesStoreError.textTooLong }
        let bytes = try envelope.wireBytes()
        do {
            let challenge = try await client.powChallenge()
            guard let nonce = await NoteProofOfWork.solve(challenge: challenge, recipientAccountId: entry.accountId.raw, envelopeBytes: bytes) else { throw NotesStoreError.proofOfWorkFailed }
            let id = try await client.send(to: entry.accountId.raw, envelopeBase64: bytes.base64EncodedString(), challenge: challenge, nonce: nonce)
            let record = NoteRecord(id: id, direction: .outbound, text: text, sentAt: Date(),
                                    sender: anonymous ? .anonymous : .verified(accountId: account.accountId.raw, nickname: account.nickname),
                                    recipientAccountId: entry.accountId.raw, readAt: nil, receivedAt: Date())
            do { try storage.save(record) } catch { lastError = error.localizedDescription }
            sent.insert(record, at: 0)
            return record
        } catch let e as NotesStoreError { throw e } catch { throw Self.mapNetwork(error) }
    }

    private static func mapNetwork(_ error: Error) -> NotesStoreError {
        switch error {
        case AccountClientError.rateLimited: return .rateLimited
        case AccountClientError.http(507): return .inboxFull
        case AccountClientError.http(404): return .recipientNotFound
        default: return .network(String(describing: error))
        }
    }

    // MARK: - Inbox actions (local first, server best-effort)

    public func markRead(_ id: String) async {
        guard let i = inbox.firstIndex(where: { $0.id == id }), inbox[i].readAt == nil else { return }
        inbox[i].readAt = Date()
        do { try storage.save(inbox[i]) } catch { lastError = error.localizedDescription }
        recount()
        if !isMock { try? await client.markRead(id: id) }
    }

    public func delete(_ record: NoteRecord) async {
        do { try storage.remove(id: record.id, direction: record.direction) } catch { lastError = error.localizedDescription }
        if record.direction == .inbound {
            inbox.removeAll { $0.id == record.id }
            recount()
            if !isMock { try? await client.delete(id: record.id) }
        } else {
            sent.removeAll { $0.id == record.id }
        }
    }

    public func block(_ record: NoteRecord) async throws -> String {
        do { return try await client.block(itemId: record.id) } catch { throw Self.mapNetwork(error) }
    }

    /// The worker checks `Array.from(excerpt).length <= 1_000` (Unicode
    /// scalars, not UTF-16 units) — truncate before sending so a long note
    /// doesn't get rejected instead of reported.
    public static let maxExcerptScalars = 1_000

    public func report(_ record: NoteRecord, reason: ReportReason, includeText: Bool) async throws {
        let excerpt = includeText ? record.text.map(Self.truncatedExcerpt) : nil
        do { _ = try await client.report(itemId: record.id, reason: reason, excerpt: excerpt) } catch { throw Self.mapNetwork(error) }
    }

    private static func truncatedExcerpt(_ text: String) -> String {
        guard text.unicodeScalars.count > maxExcerptScalars else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.prefix(maxExcerptScalars)))
    }

    public func blocks() async throws -> [BlockDTO] {
        do { return try await client.blocks() } catch { throw Self.mapNetwork(error) }
    }

    public func unblock(senderHash: String) async throws {
        do { try await client.unblock(senderHash: senderHash) } catch { throw Self.mapNetwork(error) }
    }
}
