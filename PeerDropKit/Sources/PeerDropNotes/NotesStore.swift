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
    case noteNotFound
    case network(String)
}

/// What the injected `diaryKeyHandler` decided to do with one decoded
/// `diaryKey` inbox item (spec §3.4). `installed` and `rejected` are
/// handled identically at this layer — both are terminal for the item
/// (server-side delete + cursor advance, no `NoteRecord`) — the
/// distinction only matters to the handler's own bookkeeping (e.g.
/// whether it wrote `key.enc`).
public enum DiaryKeyDisposition {
    case installed
    case rejected
    case transient
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
    /// Injected by the app layer (`PeerDropDiary`) so `PeerDropNotes` never
    /// imports `PeerDropDiary` — see spec §1 row "收件匣分流". Given the
    /// decoded `diaryKey` plaintext, the verified-sender state computed the
    /// same way as for a note, and the inbox item id; returns how `sync()`
    /// should dispose of the item (§3.4). `nil` (never set) is treated as
    /// `.transient` for every `diaryKey` item.
    public var diaryKeyHandler: ((NotePlaintext, NoteSenderState, String) async -> DiaryKeyDisposition)?
    /// Ids of inbound records whose sender block was looked up, FOUND in the
    /// directory, and did not match — a permanent mismatch, unlike a
    /// transient lookup failure. Skipped by future re-verification passes so
    /// we don't keep re-querying the directory for a note that will never
    /// verify. Per-instance only; a relaunch simply re-derives it once.
    private var confirmedMismatchIds: Set<String> = []

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
                    switch await decodeItem(item, account: account, keys: keys) {
                    case .record(let record):
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
                    case .diaryKeyResolved:
                        // §3.4 "installed"/"rejected": both delete the item and
                        // advance the cursor past it — no `NoteRecord` either way.
                        // Best-effort delete, same as the explicit `delete(_:)`
                        // API below: a failed DELETE here must not re-run the
                        // handler (and burn another OPK relay) on the next sync.
                        try? await client.delete(id: item.id)
                        lastPersistedId = item.id
                    case .diaryKeyTransient:
                        // §3.4 transient: no delete, no cursor advance, and the
                        // cursor is a single high-water mark — abort the WHOLE
                        // sync round now so a later item (a plain note, or a
                        // later page) can't get persisted and jump the cursor
                        // past this unresolved one.
                        if lastPersistedId != initialCursor { storage.lastSeenInboxId = lastPersistedId }
                        return
                    }
                }
                // Paging terminates on server-controlled input: `nextAfter`
                // is the next request cursor. Stop when the server says
                // there's no more (`nil`) or hands back the same cursor
                // again (would otherwise loop forever).
                guard let next = page.nextAfter, next != after else { break }
                after = next
            }
            lastError = nil
            // Only on a fully successful page walk: a transient directory
            // failure (rate-limited/network) during `decode` above must not
            // permanently strand a signed sender as unverified — retry a
            // bounded slice of them now that the account is reachable again.
            await reverifyUnverifiedSenders(account: account)
        } catch {
            lastError = String(describing: Self.mapNetwork(error))
            Self.logger.error("inbox sync failed: \(String(describing: error), privacy: .public)")
        }
        if lastPersistedId != initialCursor { storage.lastSeenInboxId = lastPersistedId }
    }

    /// What `decodeItem` found for one inbox item. `.record` is the existing
    /// note path (saved via `storage.save`); the `diaryKey*` cases never
    /// produce a `NoteRecord` — see §3.4 and `diaryKeyHandler`.
    private enum ItemOutcome {
        case record(NoteRecord)
        case diaryKeyResolved
        case diaryKeyTransient
    }

    private func decodeItem(_ item: InboxItemDTO, account: Account, keys: NoteRecipientKeys) async -> ItemOutcome {
        let receivedAt = Date(timeIntervalSince1970: TimeInterval(item.createdAt) / 1000)
        let readAt = item.readAt.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
        guard let bytes = Data(base64Encoded: item.envelope), let envelope = try? NoteEnvelope.fromWire(bytes),
              let plaintext = try? NoteCrypto.open(envelope, recipientAccountId: account.accountId.raw, keys: keys)
        else {
            return .record(NoteRecord(id: item.id, direction: .inbound, text: nil, sentAt: receivedAt, sender: .anonymous, recipientAccountId: nil, readAt: readAt, receivedAt: receivedAt))
        }
        if plaintext.kind == .diaryKey {
            return await decodeDiaryKey(plaintext, itemId: item.id, account: account)
        }
        let sender = await senderState(for: plaintext, account: account)
        return .record(NoteRecord(id: item.id, direction: .inbound, text: plaintext.text, sentAt: Date(timeIntervalSince1970: TimeInterval(plaintext.sentAt)),
                                  sender: sender, recipientAccountId: nil, readAt: readAt, receivedAt: receivedAt, senderBlock: plaintext.sender))
    }

    /// §3.4's three cursor rules, restricted to what `NotesStore` itself can
    /// decide: anonymity and the same sender-verification computation used
    /// for a note. Everything else (does this device hold the diary, does
    /// `openMeta` succeed, is the sender on the diary's member list) is the
    /// injected handler's call — `PeerDropDiary` owns that, not this module.
    private func decodeDiaryKey(_ plaintext: NotePlaintext, itemId: String, account: Account) async -> ItemOutcome {
        // Anonymous → rejected without ever invoking the handler: an
        // unsigned `diaryKey` plaintext carries no verifiable installer.
        guard plaintext.sender != nil else { return .diaryKeyResolved }
        // No handler registered (e.g. `DiaryStore` not wired up yet) →
        // transient, same as "this diary isn't local yet": retry later
        // rather than silently dropping a key relay.
        guard let diaryKeyHandler else { return .diaryKeyTransient }
        let sender = await senderState(for: plaintext, account: account)
        switch await diaryKeyHandler(plaintext, sender, itemId) {
        case .installed, .rejected: return .diaryKeyResolved
        case .transient: return .diaryKeyTransient
        }
    }

    /// Verified-sender computation shared by the note and `diaryKey` decode
    /// paths: `.anonymous` when there's no inner sender block, else
    /// `.unverified` unless the directory has (and signs for) a matching key.
    /// A 404 ("not found") and a network/rate-limit failure both leave the
    /// sender `.unverified` here — the difference only matters to
    /// `reverifyUnverifiedSenders`, which must retry the latter but not
    /// waste lookups on a confirmed key mismatch.
    private func senderState(for plaintext: NotePlaintext, account: Account) async -> NoteSenderState {
        guard let block = plaintext.sender else { return .anonymous }
        var sender: NoteSenderState = .unverified(accountId: block.accountId)
        if case .found(let entry) = await directoryLookup(for: block.accountId),
           NoteCrypto.verifySender(plaintext, recipientAccountId: account.accountId.raw, directorySigningKey: entry.signingKey) {
            sender = .verified(accountId: block.accountId, nickname: entry.nickname)
        }
        return sender
    }

    /// Distinguishes "the directory definitively has no such account" from
    /// "we could not reach/read the directory right now" — a plain
    /// `Entry?` can't, and conflating the two is what let a transient
    /// failure permanently downgrade a signed sender (see `NotesStoreError`
    /// F1 fix note above `decode`). `internal` (not `private`) so tests can
    /// drive `reverifySender` directly.
    enum DirectoryLookup { case found(DirectoryCache.Entry), notFound, failed }

    private func directoryLookup(for accountId: String) async -> DirectoryLookup {
        if let cached = directoryCache.get(accountId) { return .found(cached) }
        do {
            guard let entry = try await client.lookup(handle: accountId, includeBundle: false) else { return .notFound }
            directoryCache.set(accountId, signingKey: entry.signingKey, nickname: entry.nickname)
            guard let cached = directoryCache.get(accountId) else { return .failed }   // TTL <= 0 edge case
            return .found(cached)
        } catch {
            return .failed
        }
    }

    /// Reconstructs just enough of the original `NotePlaintext` from a saved
    /// `NoteRecord` to re-run `NoteCrypto.verifySender` — the record never
    /// stores the whole plaintext, only the fields the signature covers.
    /// `kind` is carried from the caller rather than hard-coded: a `diaryKey`
    /// plaintext is never persisted as a `NoteRecord` (§3.4), so every
    /// record `reverifySender` re-checks today is `.note`, but this keeps
    /// the reconstructed plaintext honest rather than silently assuming
    /// that will always stay true.
    private func verifySenderBlock(_ block: NoteSenderBlock, text: String?, sentAt: Date, kind: NoteKind, recipientAccountId: String, directorySigningKey: Data) -> Bool {
        let plaintext = NotePlaintext(kind: kind, text: text ?? "", sentAt: Int64(sentAt.timeIntervalSince1970), sender: block)
        return NoteCrypto.verifySender(plaintext, recipientAccountId: recipientAccountId, directorySigningKey: directorySigningKey)
    }

    /// Bounded retry, run at the end of every successful sync: a note whose
    /// directory lookup failed transiently (network/rate-limit — not a 404,
    /// not a key mismatch) stays `.unverified` forever otherwise, since
    /// nothing else ever revisits an already-persisted inbox record.
    ///
    /// Candidates are snapshotted as `(id, block)` pairs, NOT array indices:
    /// `NotesStore` is `@MainActor`, but the actor is released for the
    /// duration of each candidate's `await directoryLookup` — `delete(_:)`
    /// (or an earlier candidate's own promotion) can mutate `inbox`
    /// synchronously while we're suspended, so an index captured before the
    /// loop can point at the wrong record (or be out of range) by the time
    /// we come back. `reverifySender` re-resolves by id AFTER its own
    /// await and is a no-op if the id is gone or no longer `.unverified`.
    private func reverifyUnverifiedSenders(account: Account) async {
        let candidates: [(id: String, block: NoteSenderBlock)] = inbox.compactMap { record in
            guard let block = record.senderBlock, !confirmedMismatchIds.contains(record.id),
                  case .unverified = record.sender else { return nil }
            return (record.id, block)
        }
        // Memoized only for this one sync's pass: several stale candidates
        // can share a sender account that has since been deleted, and
        // without this every one of them would spend its own directory
        // lookup (and quota) on the same 404 — retried again next sync.
        var notFoundThisSync: Set<String> = []
        for candidate in candidates.prefix(20) {
            guard !notFoundThisSync.contains(candidate.block.accountId) else { continue }
            if case .notFound = await reverifySender(id: candidate.id, block: candidate.block, account: account) {
                notFoundThisSync.insert(candidate.block.accountId)
            }
        }
    }

    /// Looks up (cache-first) and, if it verifies, promotes exactly one
    /// unverified sender by id. `internal` rather than `private` so a test
    /// can drive the disappearance race directly and deterministically
    /// (delete the record, then call this with its now-stale id/block —
    /// no real concurrency needed to prove the guard below holds).
    func reverifySender(id: String, block: NoteSenderBlock, account: Account) async -> DirectoryLookup {
        let lookup = await directoryLookup(for: block.accountId)
        guard case .found(let entry) = lookup else { return lookup }
        // Re-resolve by id — never trust an index/reference captured before
        // the await above. The record may have been deleted, or (sharing
        // the same sender account as an earlier candidate in this same
        // pass) already promoted or confirmed-mismatched.
        guard let idx = inbox.firstIndex(where: { $0.id == id }), case .unverified = inbox[idx].sender else { return lookup }
        if verifySenderBlock(block, text: inbox[idx].text, sentAt: inbox[idx].sentAt, kind: .note, recipientAccountId: account.accountId.raw, directorySigningKey: entry.signingKey) {
            inbox[idx].sender = .verified(accountId: block.accountId, nickname: entry.nickname)
            do { try storage.save(inbox[idx]) } catch { lastError = error.localizedDescription }
        } else {
            confirmedMismatchIds.insert(id)
        }
        return lookup
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
        guard bytes.count <= 16 * 1024 else { throw NotesStoreError.textTooLong }
        do {
            let challenge = try await client.powChallenge()
            guard let nonce = await NoteProofOfWork.solve(challenge: challenge, recipientAccountId: entry.accountId.raw, envelopeBytes: bytes) else { throw NotesStoreError.proofOfWorkFailed }
            let id = try await client.send(to: entry.accountId.raw, envelopeBase64: bytes.base64EncodedString(), challenge: challenge, nonce: nonce)
            let record = NoteRecord(id: id, direction: .outbound, text: text, sentAt: Date(),
                                    sender: anonymous ? .anonymous : .verified(accountId: account.accountId.raw, nickname: account.nickname),
                                    recipientAccountId: entry.accountId.raw, readAt: nil, receivedAt: Date())
            if !isMock {
                do { try storage.save(record) } catch { lastError = error.localizedDescription }
            }
            sent.insert(record, at: 0)
            return record
        } catch let e as NotesStoreError { throw e } catch { throw Self.mapNetwork(error) }
    }

    private static func mapNetwork(_ error: Error) -> NotesStoreError {
        switch error {
        case AccountClientError.rateLimited: return .rateLimited
        case AccountClientError.insufficientStorage: return .inboxFull
        case AccountClientError.http(404): return .recipientNotFound
        default: return .network(String(describing: error))
        }
    }

    /// Same mapping as `mapNetwork`, except a 404 means the specific note/
    /// item is gone rather than "recipient not found" — used by the
    /// item-scoped server calls below (`send`'s 404 really does mean the
    /// recipient handle doesn't exist, so it keeps `mapNetwork`).
    private static func mapItemError(_ error: Error) -> NotesStoreError {
        switch error {
        case AccountClientError.rateLimited: return .rateLimited
        case AccountClientError.insufficientStorage: return .inboxFull
        case AccountClientError.http(404): return .noteNotFound
        default: return .network(String(describing: error))
        }
    }

    // MARK: - Inbox actions (local first, server best-effort)

    public func markRead(_ id: String) async {
        guard let i = inbox.firstIndex(where: { $0.id == id }), inbox[i].readAt == nil else { return }
        inbox[i].readAt = Date()
        if !isMock {
            do { try storage.save(inbox[i]) } catch { lastError = error.localizedDescription }
        }
        recount()
        if !isMock { try? await client.markRead(id: id) }
    }

    public func delete(_ record: NoteRecord) async {
        if !isMock {
            do { try storage.remove(id: record.id, direction: record.direction) } catch { lastError = error.localizedDescription }
        }
        if record.direction == .inbound {
            inbox.removeAll { $0.id == record.id }
            recount()
            if !isMock { try? await client.delete(id: record.id) }
        } else {
            sent.removeAll { $0.id == record.id }
        }
    }

    public func block(_ record: NoteRecord) async throws -> String {
        do { return try await client.block(itemId: record.id) } catch { throw Self.mapItemError(error) }
    }

    /// The worker checks `Array.from(excerpt).length <= 1_000` (Unicode
    /// scalars, not UTF-16 units) — truncate before sending so a long note
    /// doesn't get rejected instead of reported.
    public static let maxExcerptScalars = 1_000

    public func report(_ record: NoteRecord, reason: ReportReason, includeText: Bool) async throws {
        let excerpt = includeText ? record.text.map(Self.truncatedExcerpt) : nil
        do { _ = try await client.report(itemId: record.id, reason: reason, excerpt: excerpt) } catch { throw Self.mapItemError(error) }
    }

    private static func truncatedExcerpt(_ text: String) -> String {
        guard text.unicodeScalars.count > maxExcerptScalars else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.prefix(maxExcerptScalars)))
    }

    public func blocks() async throws -> [BlockDTO] {
        guard !isMock else { return [] }
        do { return try await client.blocks() } catch { throw Self.mapItemError(error) }
    }

    public func unblock(senderHash: String) async throws {
        guard !isMock else { return }
        do { try await client.unblock(senderHash: senderHash) } catch { throw Self.mapItemError(error) }
    }
}
