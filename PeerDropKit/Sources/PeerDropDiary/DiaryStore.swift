import Foundation
import CryptoKit
import Security
import PeerDropSecurity
import PeerDropAccount
import PeerDropNotes

/// A single diary's state as the UI sees it — `meta`/`events` are exactly
/// what is currently persisted locally (never synthesized), `isHolder`/
/// `isOwner` are derived against the signed-in account, `hasKey` reflects
/// `DiaryKeyStore`, and `pendingKey` is the complement of `hasKey`: true
/// whenever this device is a legitimate member (meta/members ARE
/// persisted) but has no working content key yet — the short-code-join
/// "waiting for a relay" state (spec §3.2/§3.3).
public struct DiaryState: Equatable, Sendable {
    public var meta: DiaryMeta
    public var events: [DiaryEvent]
    public var isHolder: Bool
    public var isOwner: Bool
    public var hasKey: Bool
    public var pendingKey: Bool

    public init(meta: DiaryMeta, events: [DiaryEvent], isHolder: Bool, isOwner: Bool, hasKey: Bool, pendingKey: Bool) {
        self.meta = meta
        self.events = events
        self.isHolder = isHolder
        self.isOwner = isOwner
        self.hasKey = hasKey
        self.pendingKey = pendingKey
    }
}

/// One row of `DiaryStore.diaries` — the list view's summary of a diary.
/// Distinct from `DiaryListRow` (the raw `GET /v3/diaries` wire shape):
/// this is derived from a diary's locally-reconciled `DiaryState`, with a
/// decrypted `name` (nil until this device has a key and has decoded it)
/// and the turn-order fields a list row actually needs to render.
public struct DiarySummary: Identifiable, Equatable, Sendable {
    public var diaryId: String
    public var name: String?
    public var memberCount: Int
    public var holderAccountId: String
    public var isMyTurn: Bool

    public var id: String { diaryId }

    public init(diaryId: String, name: String?, memberCount: Int, holderAccountId: String, isMyTurn: Bool) {
        self.diaryId = diaryId
        self.name = name
        self.memberCount = memberCount
        self.holderAccountId = holderAccountId
        self.isMyTurn = isMyTurn
    }
}

/// `@MainActor` state machine for every diary this device is a member of
/// (spec §5.1). Owns the on-disk layout under `Documents/Diary/`:
/// `<diaryId>/{key.enc via DiaryKeyStore, meta.enc, events.log via
/// DiaryEventLog, pending.enc}` plus a top-level `index.enc` (spec §3.5).
///
/// `DiaryEventLog` itself does no locking and its `load()` is O(events) —
/// its own doc comment warns callers not to run that on the main actor for
/// a long-lived diary. This store never does: every event-log read/append
/// goes through `logCoordinator`, a dedicated actor whose calls
/// necessarily hop off the main actor's executor and are serialized end to
/// end (no `await` inside its method bodies, so one call always finishes
/// before the mailbox releases the next). The one intentional exception is
/// `load()` itself, which is a plain synchronous function by design (called
/// from `init`, before any UI is up) — it hydrates the diary list from the
/// small `meta.enc` files only, leaving `events: []` until the first
/// `sync(_:)` for that diary does the real (async, coordinator-routed)
/// event reconciliation.
@MainActor
public final class DiaryStore: ObservableObject {
    @Published public private(set) var diaries: [DiarySummary] = []
    @Published public private(set) var states: [String: DiaryState] = [:]
    @Published public private(set) var lastError: String?

    private let client: DiaryClient
    private let notesClient: NotesClient
    private let accountManager: AccountManager
    private let crypto: NotesCryptoContext
    private let keyStore: DiaryKeyStore
    private let directory: URL
    private let encryptor: ChatDataEncryptor
    private let directoryCache: DirectoryCache
    private let relay: DiaryKeyRelay
    private let logCoordinator: DiaryLogCoordinator
    private let isMock: Bool
    /// Per-diary reentrancy guard for `sync(_:)` (review round 1, I2) — a
    /// second concurrent `sync` call for the SAME diary returns
    /// immediately instead of racing the first (duplicate GET meta/events
    /// pages, duplicate relay attempts). Checked/set OUTSIDE `withDiaryLock`
    /// (see its doc) specifically so this short-circuit fires before ever
    /// joining the per-diary queue, rather than after waiting a full turn
    /// for a now-redundant pass.
    private var syncing: Set<String> = []

    /// Per-diary FIFO gate (review round 2, defect 2): `sync`,
    /// `performWrite` (covering `writeEntry`/`pass`/`skip`/`comment`/
    /// `like`), `join`, `leave`, `close`, and `create` all read-modify-write
    /// this diary's on-disk state (`meta.enc`/`cursor.enc`/`pending.enc`) —
    /// running two of them concurrently for the SAME diary would race
    /// those sequences (e.g. a write's cursor check racing a sync's cursor
    /// advance, or two writers both reading `pending.enc` as empty and
    /// both proceeding). See `withDiaryLock` below.
    private var diaryGates: [String: Task<Void, Never>] = [:]

    /// Chains `body` onto whatever's already queued for `id`, so bodies
    /// for the SAME diary id always run one at a time, in call order;
    /// different diaries are fully independent (no cross-diary
    /// contention). `work` is the properly-typed task whose result/error
    /// this call actually returns; the plain `Task<Void, Never>` stored in
    /// `diaryGates` is only a completion signal for the NEXT caller to
    /// chain onto (so a slow/failing call never blocks the dictionary on a
    /// value only that one caller needed).
    ///
    /// NOT reentrant: a body must never call `withDiaryLock` again for the
    /// SAME id it's already executing under — that would await a task
    /// (itself) that can never finish, deadlocking forever. `handlePush`
    /// avoids this by never wrapping its own body in the gate — it only
    /// calls `sync(_:)` (which gates itself) and `relay.relayIfNeeded`
    /// (which doesn't touch any of `DiaryStore`'s own per-diary files).
    private func withDiaryLock<T>(_ id: String, _ body: @MainActor @escaping () async throws -> T) async throws -> T {
        let previous = diaryGates[id]
        let work = Task<T, Error> { @MainActor in
            _ = await previous?.value
            return try await body()
        }
        diaryGates[id] = Task { @MainActor in
            _ = try? await work.value
        }
        return try await work.value
    }

    public init(
        client: DiaryClient, notesClient: NotesClient, accountManager: AccountManager, crypto: NotesCryptoContext,
        keyStore: DiaryKeyStore, directory: URL, encryptor: ChatDataEncryptor, directoryCache: DirectoryCache
    ) {
        self.client = client
        self.notesClient = notesClient
        self.accountManager = accountManager
        self.crypto = crypto
        self.keyStore = keyStore
        self.directory = directory
        self.encryptor = encryptor
        self.directoryCache = directoryCache
        self.relay = DiaryKeyRelay(notesClient: notesClient, crypto: crypto, keyStore: keyStore,
                                   relayStore: DiaryKeyRelayStore(directory: directory, encryptor: encryptor))
        self.logCoordinator = DiaryLogCoordinator(encryptor: encryptor)
        self.isMock = false
        load()
    }

    /// Screenshot mode: fixed content, no network, no disk — mirrors
    /// `NotesStore(mockInbox:sent:)`.
    private struct NoopCrypto: NotesCryptoContext {
        func recipientKeys() throws -> NoteRecipientKeys { throw DiaryError.network("no_account") }
        func signer(accountId: String, nickname: String?) throws -> NoteSigner { throw DiaryError.network("no_account") }
    }

    public init(mock diaries: [DiarySummary], states: [String: DiaryState]) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DiaryStore-mock-\(UUID().uuidString)", isDirectory: true)
        let account = AccountClient(baseURL: URL(string: "https://screenshot.invalid")!)
        let mockEncryptor = ChatDataEncryptor(testKey: SymmetricKey(size: .bits256))
        self.client = DiaryClient(account: account)
        self.notesClient = NotesClient(account: account)
        self.accountManager = AccountManager(mock: Account(accountId: AccountID(raw: "PDRPDEM0")!, nickname: nil, mailboxId: "screenshot", createdAt: Date()))
        self.crypto = NoopCrypto()
        // Same root as `directory` — spec §3.5 lays `key.enc` out under the
        // SAME per-diary folder as `meta.enc`/`events.log`/`pending.enc`.
        self.keyStore = DiaryKeyStore(directory: tempDir, encryptor: mockEncryptor)
        self.directory = tempDir
        self.encryptor = mockEncryptor
        self.directoryCache = DirectoryCache()
        self.relay = DiaryKeyRelay(notesClient: self.notesClient, crypto: self.crypto, keyStore: self.keyStore,
                                   relayStore: DiaryKeyRelayStore(directory: tempDir, encryptor: mockEncryptor))
        self.logCoordinator = DiaryLogCoordinator(encryptor: mockEncryptor)
        self.isMock = true
        self.diaries = diaries
        self.states = states
    }

    // MARK: - Load / list

    /// Synchronous, disk-only hydration from `index.enc` + each known
    /// diary's `meta.enc` (small files) — deliberately does NOT read any
    /// `events.log` (see the type doc). Called once from the real `init`.
    public func load() {
        guard !isMock else { return }
        for id in readIndex() {
            guard let meta = readMeta(id) else { continue }
            refreshSummary(id: id, meta: meta, events: states[id]?.events ?? [])
        }
    }

    /// Refreshes EVERY diary this account belongs to (≤ 20 — review round
    /// 1, I5: this used to only pull state for diaries not yet known
    /// locally, so an already-known diary's turn order/events went stale
    /// forever unless something else happened to call `sync(_:)` for it).
    /// `client.list()` is the full membership list, so a plain `sync` per
    /// row covers both "discover a diary this device missed create/join
    /// for" and "refresh one it already knows about".
    public func syncList() async {
        guard !isMock else { return }
        do {
            let rows = try await client.list()
            for row in rows {
                await sync(row.diaryId)
            }
            lastError = nil
        } catch {
            lastError = String(describing: Self.mapError(error))
        }
    }

    // MARK: - Sync (the turn-order/content source of truth)

    /// `GET /v3/diaries/:id` overwrites the local turn-order fields
    /// (`members`/`holderIndex`/`ownerAccountId`/`state`/`seq`) — this is
    /// the ONLY source of truth for whose turn it is (spec §5.1); events
    /// are fetched separately and only ever upsert by `seq`, never replay
    /// the turn order. Every event-log read/append goes through
    /// `logCoordinator`, off the main actor. After reconciling, relays this
    /// device's key (if it has one) to every member whose `join` event is
    /// visible and not within the relay's own 24h dedupe window.
    ///
    /// Guarded against reentrancy per diary (review round 1, I2): a second
    /// concurrent call for the same `id` returns immediately rather than
    /// racing the first. Also flushes any previously-stuck pending write
    /// FIRST (round 1, C1), and uses a persisted, GET-driven-only cursor —
    /// never the event log's own `maxSeq` — for `since` (round 1, C2; see
    /// `readCursor`/`writeCursor`'s doc).
    public func sync(_ id: String) async {
        guard !isMock else { return }
        guard !syncing.contains(id) else { return }
        syncing.insert(id)
        defer { syncing.remove(id) }

        try? await withDiaryLock(id) { [self] in
            let flushedCleanly = await flushPendingIfPossible(id: id)

            do {
                let meta = try await client.get(id)
                let key = keyStore.key(for: id)
                var localMeta = meta
                if let key, let cipherData = Data(base64Encoded: meta.metaCipher),
                   let name = try? DiaryCrypto.openMeta(cipherData, key: key, diaryId: id, keyEpoch: meta.keyEpoch) {
                    localMeta.name = name
                } else {
                    localMeta.name = readMeta(id)?.name
                }
                persistMeta(id, localMeta)
                addToIndex(id)

                let logURL = eventsLogURL(id)
                var since = readCursor(id)
                while true {
                    let sinceBeforePage = since
                    let (events, nextSince) = try await client.events(id: id, since: since, limit: 100)
                    for event in events {
                        let decoded = withDecodedPayload(event, id: id, key: key)
                        await logCoordinator.append(decoded, url: logURL)
                    }
                    // The cursor only ever advances via THIS paged, contiguous
                    // fetch — never via a write's own `performWrite`/
                    // `sendPendingEvent` append, which can land arbitrarily far
                    // ahead (e.g. seq 16 while a gap of 11–15 from other
                    // members hasn't been synced yet). Advancing here, after
                    // every page, keeps a long paginated catch-up resumable
                    // even if it's interrupted partway through.
                    if let maxFetched = events.map(\.seq).max() {
                        since = maxFetched
                        writeCursor(id, since)
                    }
                    // Review round 4, I1: keep paging while the server says
                    // there IS another page (`nextSince != nil`) AND this page
                    // actually moved us forward. The old test — `next != since`
                    // — could never be true: the worker sets `nextSince` to the
                    // LAST seq of the page it just served (`diaryRoom.ts`
                    // `out.nextSince = page[page.length - 1].seq`), which is
                    // exactly the `maxFetched` we just assigned to `since`, so
                    // every paginated catch-up stopped dead after page 1 and
                    // only crept forward one page per `sync`.
                    //
                    // `since` is deliberately NOT re-assigned from `nextSince`:
                    // the two are the same value under the worker's contract,
                    // and re-requesting from our own highest FETCHED seq is the
                    // safe direction if a future server ever returns a larger
                    // `nextSince` (at worst one redundant page; never a skipped
                    // event). The strict `>` also guarantees termination — each
                    // extra round trip must raise `since` by at least 1.
                    guard nextSince != nil, since > sinceBeforePage else { break }
                }

                let finalEvents = await logCoordinator.load(url: logURL).events
                refreshSummary(id: id, meta: localMeta, events: finalEvents)
                // Review round 2, defect 1: don't clobber a `flushPendingIfPossible`
                // failure's `lastError` with an unconditional nil just because
                // the (unrelated) GET meta/events work below happened to succeed.
                if flushedCleanly { lastError = nil }

                if let myId = accountManager.account?.accountId.raw {
                    let myNickname = accountManager.account?.nickname
                    for event in finalEvents where event.type == .join && event.authorAccountId != myId {
                        await relay.relayIfNeeded(
                            diaryId: id, newMember: event.authorAccountId, metaCipher: localMeta.metaCipher,
                            senderAccountId: myId, senderNickname: myNickname, force: false)
                    }
                }
            } catch {
                lastError = String(describing: Self.mapError(error))
            }
        }
    }

    /// Best-effort resend of a previously-stuck pending event, run at the
    /// top of every `sync(_:)` (review round 1, C1) so a device coming
    /// back online doesn't have to wait for the next explicit write action
    /// to clear a `.transient` pending event. Failures here never abort
    /// the rest of `sync` — the GET-meta/events reconciliation below is
    /// still worth doing regardless of whether the flush succeeded.
    ///
    /// Review round 2, defect 1: mirrors `performWrite`'s own resend-first
    /// handling exactly — `.transient` keeps `pending.enc` in place (so
    /// the next `sync`/write retries the SAME event); any other failure
    /// (403/400/…) clears it, since a dead pending event would otherwise
    /// be resent and fail identically on every future `sync` forever.
    /// Either failure surfaces the mapped `DiaryError` in `lastError`.
    /// Returns `true` when there was nothing to flush or the flush
    /// succeeded — `sync` uses this to avoid immediately clobbering a
    /// just-set failure `lastError` with an unconditional `nil` once its
    /// own (unrelated) GET meta/events work succeeds.
    @discardableResult
    private func flushPendingIfPossible(id: String) async -> Bool {
        guard let pending = readPendingEvent(id) else { return true }
        do {
            _ = try await sendPendingEvent(id: id, pending: pending)
            return true
        } catch {
            let diaryError = Self.mapError(error)
            lastError = String(describing: diaryError)
            if case .transient = diaryError {
                // keep pending.enc — resend next time
            } else {
                clearPendingEvent(id)
            }
            return false
        }
    }

    // MARK: - Create

    /// Generates the `diaryId` (client ULID) and content key, seals the
    /// (name-only) meta plaintext, and writes `key.enc` — ALL before the
    /// first `POST /v3/diaries` (spec §0/§5.1). A "pending create" marker
    /// persists that same `{diaryId, metaCipher}` pair so a transient POST
    /// failure (network/5xx/429) can be retried with the SAME diaryId
    /// rather than minting a new one on the next call — the worker's own
    /// create route is idempotent by `diaryId` for exactly this reason.
    public func create(name: String) async throws -> String {
        guard !isMock else { throw DiaryError.network("mock") }
        guard let myId = accountManager.account?.accountId.raw else { throw DiaryError.network("no_account") }

        // A stuck pending create is only resumable for the SAME name
        // (review round 1, I1) — the marker's `diaryId`/`metaCipher` were
        // sealed for whatever name the FIRST attempt asked for, so
        // resuming it for a different name would silently return a diary
        // sealed with the wrong name. Abandon it (and its key — nothing
        // else will ever reference that id) and mint fresh material.
        var existingPending = readPendingCreate()
        if let existing = existingPending, existing.name != name {
            try? keyStore.removeKey(for: existing.diaryId)
            clearPendingCreate()
            existingPending = nil
        }

        let pending: PendingCreate
        if let existingPending {
            pending = existingPending
        } else {
            let diaryId = DiaryULID.generate()
            let key = SymmetricKey(size: .bits256)
            let metaCipher: String
            do {
                metaCipher = try DiaryCrypto.sealMeta(name: name, key: key, diaryId: diaryId, keyEpoch: 1).base64EncodedString()
            } catch {
                let err = DiaryError.network("seal_failed")
                lastError = String(describing: err)
                throw err
            }
            do {
                try keyStore.save(key: key, for: diaryId)
                let created = PendingCreate(diaryId: diaryId, name: name, metaCipher: metaCipher)
                try writePendingCreate(created)
                pending = created
            } catch {
                let err = DiaryError.network("persist_failed")
                lastError = String(describing: err)
                throw err
            }
        }

        // Review round 2, defect 2: gate the POST + local persist by the
        // now-known `diaryId`, same as every other per-diary operation.
        return try await withDiaryLock(pending.diaryId) { [self] in
            do {
                // `pending.diaryId` — the client-generated id `key.enc` was
                // already saved under — is authoritative for local storage; the
                // worker's create route is idempotent BY that same diaryId and
                // always echoes it back unchanged (spec §2.1), so `r.diaryId`
                // is only used as a defensive sanity check, never to re-key
                // where this diary's files live locally.
                let r = try await client.create(diaryId: pending.diaryId, metaCipher: pending.metaCipher)
                let meta = DiaryMeta(
                    diaryId: pending.diaryId, ownerAccountId: myId, members: [myId], holderIndex: 0, seq: 0, state: "open",
                    keyEpoch: 1, metaCipher: pending.metaCipher, inviteCode: r.inviteCode, name: pending.name)
                persistMeta(pending.diaryId, meta)
                addToIndex(pending.diaryId)
                clearPendingCreate()
                refreshSummary(id: pending.diaryId, meta: meta, events: [])
                lastError = nil
                return pending.diaryId
            } catch {
                let diaryError = Self.mapError(error)
                lastError = String(describing: diaryError)
                if case .transient = diaryError {
                    // Leave the pending-create marker so the next `create(name:)`
                    // call resends with the SAME diaryId/metaCipher.
                } else {
                    clearPendingCreate()
                }
                throw diaryError
            }
        }
    }

    // MARK: - Join

    /// `peerdrop://diary/<diaryId>?code=<inviteCode>#k=<base64url key>`.
    /// Persists meta+members BEFORE attempting to open the key (spec §3.2)
    /// — a structurally malformed LINK (no `diary` host, no id, no code)
    /// throws before any network call, but a missing/wrong KEY never
    /// aborts the join itself: the fragment never reaches the server, so
    /// the join API call only needs `diaryId`+`code`. A key that fails to
    /// open `metaCipher` (or is absent) just leaves the diary in the
    /// `pendingKey` state, eligible for a later relay (§3.3).
    public func join(link: URL) async throws -> String {
        guard !isMock else { throw DiaryError.network("mock") }
        guard let parsed = DiaryInviteLink.parse(link) else { throw DiaryError.badId }
        return try await performJoin(diaryId: parsed.diaryId, code: parsed.code, key: parsed.key)
    }

    /// Join by short code alone — no key ever accompanies this path, so the
    /// diary always starts `pendingKey` until some other member's device
    /// relays the key (spec §3.3).
    public func join(code: String) async throws -> String {
        guard !isMock else { throw DiaryError.network("mock") }
        do {
            let meta = try await client.joinByCode(code)
            // Review round 2, defect 2: the diaryId is only known once the
            // response returns — gate just the local persist by it.
            return try await withDiaryLock(meta.diaryId) { [self] in
                persistMeta(meta.diaryId, meta)
                addToIndex(meta.diaryId)
                refreshSummary(id: meta.diaryId, meta: meta, events: [])
                lastError = nil
                return meta.diaryId
            }
        } catch {
            let diaryError = Self.mapError(error)
            lastError = String(describing: diaryError)
            throw diaryError
        }
    }

    private func performJoin(diaryId: String, code: String, key keyData: Data?) async throws -> String {
        do {
            let meta = try await client.join(id: diaryId, code: code)
            // Review round 2, defect 2: gate the persist-meta/key-install
            // sequence below by `diaryId` (known upfront for a link join).
            return try await withDiaryLock(diaryId) { [self] in
                // Persist meta + members BEFORE validating the key — spec §3.2.
                persistMeta(meta.diaryId, meta)
                addToIndex(meta.diaryId)

                var finalMeta = meta
                if let keyData, keyData.count == 32, let cipherData = Data(base64Encoded: meta.metaCipher),
                   let name = try? DiaryCrypto.openMeta(cipherData, key: SymmetricKey(data: keyData), diaryId: meta.diaryId, keyEpoch: meta.keyEpoch) {
                    try? keyStore.save(key: SymmetricKey(data: keyData), for: meta.diaryId)
                    finalMeta.name = name
                    persistMeta(meta.diaryId, finalMeta)
                }

                refreshSummary(id: meta.diaryId, meta: finalMeta, events: [])
                lastError = nil
                return meta.diaryId
            }
        } catch {
            let diaryError = Self.mapError(error)
            lastError = String(describing: diaryError)
            throw diaryError
        }
    }

    // MARK: - Leave / close

    public func leave(_ id: String) async throws {
        guard !isMock else { throw DiaryError.network("mock") }
        do {
            try await client.leave(id)
            try await withDiaryLock(id) { [self] in
                removeFromIndex(id)
                states[id] = nil
                diaries.removeAll { $0.diaryId == id }
                lastError = nil
            }
        } catch {
            let diaryError = Self.mapError(error)
            lastError = String(describing: diaryError)
            throw diaryError
        }
    }

    public func close(_ id: String) async throws {
        guard !isMock else { throw DiaryError.network("mock") }
        do {
            try await client.close(id)
            try await withDiaryLock(id) { [self] in
                if let meta = readMeta(id) {
                    let updated = DiaryMeta(
                        diaryId: meta.diaryId, ownerAccountId: meta.ownerAccountId, members: meta.members,
                        holderIndex: meta.holderIndex, seq: meta.seq, state: "closed", keyEpoch: meta.keyEpoch,
                        metaCipher: meta.metaCipher, inviteCode: meta.inviteCode, name: meta.name)
                    persistMeta(id, updated)
                    refreshSummary(id: id, meta: updated, events: states[id]?.events ?? [])
                }
                lastError = nil
            }
        } catch {
            let diaryError = Self.mapError(error)
            lastError = String(describing: diaryError)
            throw diaryError
        }
    }

    // MARK: - Invite (Task 6: DiaryInviteSheet — spec §5.2/§6)

    /// `POST /v3/diaries/:id/invite/reset` — owner-only (spec §2.3); the
    /// previous code stops working immediately, the diary's content key is
    /// unaffected (spec §6: "重設邀請碼只讓舊碼失效，金鑰不變"). Updates the
    /// locally persisted `inviteCode` on success, same gate/refresh pattern
    /// as `close(_:)`.
    public func resetInvite(_ id: String) async throws -> String {
        guard !isMock else { throw DiaryError.network("mock") }
        do {
            let code = try await client.resetInvite(id)
            try await withDiaryLock(id) { [self] in
                if let meta = readMeta(id) {
                    let updated = DiaryMeta(
                        diaryId: meta.diaryId, ownerAccountId: meta.ownerAccountId, members: meta.members,
                        holderIndex: meta.holderIndex, seq: meta.seq, state: meta.state, keyEpoch: meta.keyEpoch,
                        metaCipher: meta.metaCipher, inviteCode: code, name: meta.name)
                    persistMeta(id, updated)
                    refreshSummary(id: id, meta: updated, events: states[id]?.events ?? [])
                }
            }
            lastError = nil
            return code
        } catch {
            let diaryError = Self.mapError(error)
            lastError = String(describing: diaryError)
            throw diaryError
        }
    }

    /// This device's shareable invite link for `id` (spec §3.2:
    /// `peerdrop://diary/<diaryId>?code=<inviteCode>#k=<base64url key>`) —
    /// nil unless BOTH the owner-only `inviteCode` (spec §2.3: `GET
    /// /v3/diaries/:id`'s `inviteCode` is only ever populated for the
    /// owner) and this device's own content key are locally available. A
    /// non-owner (or an owner without a working key yet) simply has
    /// nothing shareable — `DiaryInviteSheet` falls back to code-only or a
    /// "waiting for key" state in that case. Pure/synchronous, no I/O
    /// beyond what `readMeta`/`keyStore.key` already do; never sent over
    /// the wire itself.
    public func inviteLink(for id: String) -> URL? {
        guard let meta = readMeta(id), let code = meta.inviteCode, let key = keyStore.key(for: id) else { return nil }
        guard var comps = URLComponents(string: "peerdrop://diary/\(id)") else { return nil }
        comps.queryItems = [URLQueryItem(name: "code", value: code)]
        comps.fragment = "k=" + key.withUnsafeBytes { Data($0) }.base64URLEncodedString()
        return comps.url
    }

    // MARK: - Writing (entry / pass / skip / comment / like)

    /// Requires a working local key — an entry can't be sealed without one.
    public func writeEntry(_ id: String, text: String) async throws {
        guard !isMock else { throw DiaryError.network("mock") }
        guard let key = keyStore.key(for: id) else { throw DiaryError.noKey }
        guard let myId = accountManager.account?.accountId.raw else { throw DiaryError.network("no_account") }
        try await performWrite(id: id, type: .entry, refSeq: nil) { eventId in
            try DiaryCrypto.seal(payload: DiaryPayload(kind: .entry, text: text), key: key, diaryId: id,
                                  authorAccountId: myId, eventId: eventId, maxScalars: DiaryCrypto.maxEntryScalars).base64EncodedString()
        }
    }

    public func pass(_ id: String) async throws {
        guard !isMock else { throw DiaryError.network("mock") }
        try await performWrite(id: id, type: .pass, refSeq: nil, seal: nil)
    }

    public func skip(_ id: String) async throws {
        guard !isMock else { throw DiaryError.network("mock") }
        try await performWrite(id: id, type: .skip, refSeq: nil, seal: nil)
    }

    public func comment(_ id: String, seq: Int, text: String) async throws {
        guard !isMock else { throw DiaryError.network("mock") }
        guard let key = keyStore.key(for: id) else { throw DiaryError.noKey }
        guard let myId = accountManager.account?.accountId.raw else { throw DiaryError.network("no_account") }
        try await performWrite(id: id, type: .comment, refSeq: seq) { eventId in
            try DiaryCrypto.seal(payload: DiaryPayload(kind: .comment, text: text), key: key, diaryId: id,
                                  authorAccountId: myId, eventId: eventId, maxScalars: DiaryCrypto.maxCommentScalars).base64EncodedString()
        }
    }

    public func like(_ id: String, seq: Int) async throws {
        guard !isMock else { throw DiaryError.network("mock") }
        try await performWrite(id: id, type: .like, refSeq: seq, seal: nil)
    }

    /// Shared write path for every `POST /events` type (spec §5.1).
    ///
    /// Review round 1, C1: a previously-stuck pending event (only possible
    /// after an earlier `.transient` failure — anything else clears it
    /// immediately) is ALWAYS resolved FIRST, as its OWN complete POST +
    /// server-fetch, before this call's actual request is even sealed. The
    /// two must never be conflated: the old bug resent the STUCK event and
    /// reported success while silently discarding the caller's new text.
    /// - If that resend still fails `.transient`, this call aborts
    ///   entirely — `pending.enc` is untouched (still the OLD event), and
    ///   `DiaryError.transient("pending")` is thrown so the caller's new
    ///   text is never lost (it was never sealed/sent at all; the caller
    ///   still has it and can retry).
    /// - Any other resend failure clears `pending.enc` and this call falls
    ///   through to attempt its OWN request as a fresh write.
    /// - A successful resend clears `pending.enc` and this call proceeds
    ///   with its own request as a SECOND, independent `POST /events`.
    ///
    /// Only after the above is the NEW pending event built (fresh
    /// `eventId`, sealed with THIS call's `type`/`refSeq`/`seal`), written
    /// to `pending.enc`, and sent — same success/failure handling as
    /// above. The worker's `POST /events` idempotency-by-`eventId` is what
    /// makes resending an old pending event (rather than discarding it)
    /// safe: a prior attempt may have partially succeeded server-side
    /// despite the client seeing a 5xx (spec §2.2: "D1 寫入必須成功才回
    /// 2xx").
    @discardableResult
    private func performWrite(id: String, type: DiaryEventType, refSeq: Int?, seal: ((String) throws -> String)? = nil) async throws -> DiaryEvent {
        guard !isMock else { throw DiaryError.network("mock") }
        guard readMeta(id) != nil else { throw DiaryError.notFound }

        // Review round 2, defect 2: the whole read-modify-write sequence
        // below (pending.enc/cursor.enc/meta.enc) is gated per-diary so it
        // can never interleave with a concurrent `sync(_:)`/`join`/`leave`/
        // `close`/`create` for the SAME id.
        return try await withDiaryLock(id) { [self] in
            if let existingPending = readPendingEvent(id) {
                do {
                    _ = try await sendPendingEvent(id: id, pending: existingPending)
                    lastError = nil
                } catch {
                    let diaryError = Self.mapError(error)
                    lastError = String(describing: diaryError)
                    if case .transient = diaryError {
                        throw DiaryError.transient("pending")
                    }
                    clearPendingEvent(id)
                }
            }

            let eventId = DiaryULID.generate()
            var payloadCipher: String?
            if let seal {
                do {
                    payloadCipher = try seal(eventId)
                } catch DiaryCryptoError.oversized {
                    let err = DiaryError.tooLarge
                    lastError = String(describing: err)
                    throw err
                } catch {
                    let err = DiaryError.network(String(describing: error))
                    lastError = String(describing: err)
                    throw err
                }
            }
            let fresh = PendingEvent(eventId: eventId, type: type, refSeq: refSeq, payloadCipher: payloadCipher)
            do {
                try writePendingEvent(id, fresh)
            } catch {
                let err = DiaryError.network("persist_failed")
                lastError = String(describing: err)
                throw err
            }

            do {
                let event = try await sendPendingEvent(id: id, pending: fresh)
                lastError = nil
                return event
            } catch {
                let diaryError = Self.mapError(error)
                lastError = String(describing: diaryError)
                if case .transient = diaryError {
                    throw diaryError   // keep pending.enc — resend next call
                } else {
                    clearPendingEvent(id)
                    throw diaryError
                }
            }
        }
    }

    /// POSTs one pending event, fetches the canonical event back from the
    /// server (never synthesized locally), appends it to the log, and
    /// clears `pending.enc` — all only on SUCCESS; on failure this rethrows
    /// without touching `pending.enc`, leaving the caller (`performWrite`
    /// or `flushPendingIfPossible`) to decide whether to keep or clear it.
    ///
    /// Advances the persisted sync cursor (`syncedThrough`) ONLY when the
    /// fetched event is exactly the next contiguous seq (review round 1,
    /// C2): a write can land far ahead of what a paged `sync(_:)` has seen
    /// (e.g. this device posts seq 16 while other members' seq 11–15
    /// haven't been synced yet) — advancing the cursor there would
    /// permanently skip 11–15 on every future sync (and, with it, any
    /// `join` event in that range that should have driven a key relay).
    @discardableResult
    private func sendPendingEvent(id: String, pending: PendingEvent) async throws -> DiaryEvent {
        let r = try await client.postEvent(id: id, eventId: pending.eventId, type: pending.type, refSeq: pending.refSeq, payloadCipher: pending.payloadCipher)
        let fetched = try await client.event(id: id, seq: r.seq)
        let decoded = withDecodedPayload(fetched, id: id, key: keyStore.key(for: id))
        await logCoordinator.append(decoded, url: eventsLogURL(id))
        clearPendingEvent(id)

        let cursor = readCursor(id)
        if decoded.seq == cursor + 1 {
            writeCursor(id, decoded.seq)
        }

        var events = states[id]?.events ?? []
        events.removeAll { $0.seq == decoded.seq }
        events.append(decoded)
        events.sort { $0.seq < $1.seq }

        if let updatedMeta = applyPostResult(id: id, seq: r.seq, holderIndex: r.holderIndex) {
            refreshSummary(id: id, meta: updatedMeta, events: events)
        }
        return decoded
    }

    // MARK: - Key request / relay hookup

    public func requestKey(_ id: String) async throws {
        guard !isMock else { throw DiaryError.network("mock") }
        do {
            try await client.requestKey(id)
            lastError = nil
        } catch {
            let diaryError = Self.mapError(error)
            lastError = String(describing: diaryError)
            throw diaryError
        }
    }

    /// Called for every diary push (spec §4): always re-syncs. A
    /// `diaryKeyRequest` push additionally force-relays — bypassing the
    /// relay's 24h dedupe (the requester explicitly asked again) — but
    /// ONLY when the push carries the specific member who asked
    /// (`{type:"diaryKeyRequest", diaryId, accountId}`, spec §4; the
    /// worker always includes it). Review round 3: dropped the
    /// no-`accountId` fan-out-to-every-`join`-event-author entirely — with
    /// no `accountId` this is just `sync(diaryId)`, whose own un-forced,
    /// deduped relay pass already covers every un-relayed `join` event; a
    /// second, forced pass over the same events had no real payload
    /// (`diaryKeyRequest` always names who's asking) and, before round 2's
    /// defect-3 fix, could double-send to members `sync`'s own pass had
    /// only JUST relayed to.
    ///
    /// Review round 2, defect 3: the targeted relay runs BEFORE `sync`,
    /// not after — a successful send persists the dedupe entry
    /// immediately, so `sync`'s own un-forced pass (`force: false`) then
    /// sees it and skips that member, instead of both firing and burning
    /// two OPKs for one request.
    public func handlePush(kind: String, diaryId: String, accountId: String? = nil) async {
        guard kind == "diaryKeyRequest", let accountId else {
            await sync(diaryId)
            return
        }
        if let myId = accountManager.account?.accountId.raw, let meta = readMeta(diaryId) {
            let myNickname = accountManager.account?.nickname
            await relay.relayIfNeeded(
                diaryId: diaryId, newMember: accountId, metaCipher: meta.metaCipher,
                senderAccountId: myId, senderNickname: myNickname, force: true)
        }
        await sync(diaryId)
    }

    /// The `NotesStore.diaryKeyHandler` hookup (spec §3.3 step 5/§3.4),
    /// called with an already-decoded `diaryKey` plaintext and its
    /// verified-sender state:
    /// - the diary isn't known locally at all (no `meta.enc`) → `.transient`
    ///   (retry on a later inbox sync; `NotesStore` won't advance its
    ///   cursor past this item for a transient disposition);
    /// - an anonymous or merely-`.unverified` sender, or a verified sender
    ///   who isn't in the diary's persisted member list → `.rejected`;
    /// - a `keyEpoch` other than 1, a malformed key, or a key that fails
    ///   to open the diary's persisted `metaCipher` → `.rejected`;
    /// - otherwise: save the key, refresh local state, → `.installed`.
    public func acceptRelayedKey(_ plaintext: NotePlaintext, sender: NoteSenderState) async -> DiaryKeyDisposition {
        struct RelayPayload: Decodable { let diaryId: String; let keyEpoch: UInt32; let key: String }
        guard let jsonData = plaintext.text.data(using: .utf8),
              let payload = try? JSONDecoder().decode(RelayPayload.self, from: jsonData)
        else { return .rejected }

        // `payload.diaryId` is attacker-controlled (it comes straight out
        // of a note's decrypted text) and is about to be used to build a
        // file path (`diaryDir(id)`/`metaURL(id)`) — validate its shape
        // BEFORE that happens (review round 1, minor), same pattern
        // `DiaryClient` already enforces for every id it embeds in a URL.
        guard payload.diaryId.range(of: Self.diaryIdPattern, options: .regularExpression) != nil else { return .rejected }

        // Review round 3: gated the same as sync/performWrite/join/leave/
        // close/create — this reads meta.enc/members and writes key.enc,
        // the exact per-diary state those already serialize against each
        // other. The `.transient` "diary not known locally" outcome is
        // INSIDE the gate too (not specialcased out): there's a real
        // diaryId to lock on by this point, and gating it means a
        // concurrent `sync`/`join` that's ABOUT to persist this diary's
        // meta.enc can't race a relayed key arriving at almost the same
        // moment. The closure never actually throws; `?? .rejected` is
        // just a safe fallback for `withDiaryLock`'s `throws` signature.
        let disposition = try? await withDiaryLock(payload.diaryId) { [self] () -> DiaryKeyDisposition in
            guard let meta = readMeta(payload.diaryId) else { return .transient }

            switch sender {
            case .anonymous, .unverified:
                return .rejected
            case .verified(let accountId, _):
                guard meta.members.contains(accountId) else { return .rejected }
            }

            guard payload.keyEpoch == 1,
                  let keyData = Data(base64Encoded: payload.key), keyData.count == 32,
                  let metaCipherData = Data(base64Encoded: meta.metaCipher)
            else { return .rejected }

            let key = SymmetricKey(data: keyData)
            guard let name = try? DiaryCrypto.openMeta(metaCipherData, key: key, diaryId: payload.diaryId, keyEpoch: payload.keyEpoch) else {
                return .rejected
            }
            do {
                try keyStore.save(key: key, for: payload.diaryId)
            } catch {
                return .rejected
            }

            var updated = meta
            updated.name = name
            persistMeta(payload.diaryId, updated)
            refreshSummary(id: payload.diaryId, meta: updated, events: states[payload.diaryId]?.events ?? [])
            return .installed
        }
        return disposition ?? .rejected
    }

    // MARK: - Report

    public static let maxExcerptScalars = 1_000

    public func report(_ id: String, seq: Int, reason: ReportReason, includeText: Bool) async throws {
        guard !isMock else { throw DiaryError.network("mock") }
        var excerpt: String?
        if includeText {
            let events: [DiaryEvent] = states[id]?.events ?? []
            let entryText: String? = events.first(where: { $0.seq == seq })?.payload?.text
            excerpt = entryText.map(Self.truncatedExcerpt)
        }
        do {
            _ = try await client.report(id: id, seq: seq, reason: reason, excerpt: excerpt)
            lastError = nil
        } catch {
            let diaryError = Self.mapError(error)
            lastError = String(describing: diaryError)
            throw diaryError
        }
    }

    private static func truncatedExcerpt(_ text: String) -> String {
        guard text.unicodeScalars.count > maxExcerptScalars else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.prefix(maxExcerptScalars)))
    }

    // MARK: - Shared state reconciliation

    /// Rebuilds `states[id]`/`diaries` from already-known meta/events —
    /// pure, synchronous, no I/O — so every call site can pass in whatever
    /// it already has in hand (freshly fetched, freshly persisted, or just
    /// an unaffected carry-over) instead of this doing its own disk/log
    /// read.
    private func refreshSummary(id: String, meta: DiaryMeta, events: [DiaryEvent]) {
        let hasKey = keyStore.key(for: id) != nil
        let myId = accountManager.account?.accountId.raw
        let isHolder = myId != nil && meta.members.indices.contains(meta.holderIndex) && meta.members[meta.holderIndex] == myId
        let isOwner = myId != nil && meta.ownerAccountId == myId
        states[id] = DiaryState(meta: meta, events: events, isHolder: isHolder, isOwner: isOwner, hasKey: hasKey, pendingKey: !hasKey)

        let holderId = meta.members.indices.contains(meta.holderIndex) ? meta.members[meta.holderIndex] : meta.ownerAccountId
        let summary = DiarySummary(diaryId: id, name: meta.name, memberCount: meta.members.count, holderAccountId: holderId, isMyTurn: isHolder)
        if let idx = diaries.firstIndex(where: { $0.diaryId == id }) {
            diaries[idx] = summary
        } else {
            diaries.append(summary)
        }
    }

    /// A `POST /events` response's `holderIndex` reflects the diary's
    /// CURRENT turn state (spec §5.1: "冪等 200 的 holderIndex 是當下
    /// meta") — but only if it isn't stale relative to what this device
    /// already knows: if a fuller `sync(_:)` has already observed a higher
    /// `seq` than this response names, applying it would regress the turn
    /// order. Returns the meta to use afterward (updated or unchanged), or
    /// nil if the diary has no persisted meta at all (shouldn't happen —
    /// `performWrite` already required one).
    private func applyPostResult(id: String, seq: Int, holderIndex: Int) -> DiaryMeta? {
        guard let meta = readMeta(id) else { return nil }
        guard seq > meta.seq else { return meta }
        let updated = DiaryMeta(
            diaryId: meta.diaryId, ownerAccountId: meta.ownerAccountId, members: meta.members,
            holderIndex: holderIndex, seq: seq, state: meta.state, keyEpoch: meta.keyEpoch,
            metaCipher: meta.metaCipher, inviteCode: meta.inviteCode, name: meta.name)
        persistMeta(id, updated)
        return updated
    }

    /// Decrypts an `entry`/`comment` event's payload when this device has
    /// a key — leaves it (and any other event type) untouched otherwise. A
    /// decryption failure (wrong key, tampered/oversized content) just
    /// leaves `payload` nil; the event itself is still kept (spec §3.1:
    /// UI shows "內容無法顯示" for that one entry, not a sync failure).
    private func withDecodedPayload(_ event: DiaryEvent, id: String, key: SymmetricKey?) -> DiaryEvent {
        guard let key, let cipherB64 = event.payloadCipher, event.type == .entry || event.type == .comment,
              let data = Data(base64Encoded: cipherB64)
        else { return event }
        let maxScalars = event.type == .entry ? DiaryCrypto.maxEntryScalars : DiaryCrypto.maxCommentScalars
        guard let payload = try? DiaryCrypto.open(data, key: key, diaryId: id, authorAccountId: event.authorAccountId, eventId: event.eventId, maxScalars: maxScalars) else {
            return event
        }
        var updated = event
        updated.payload = payload
        return updated
    }

    private static func mapError(_ error: Error) -> DiaryError {
        error as? DiaryError ?? .network(String(describing: error))
    }

    /// Same shape `DiaryClient`'s own path validation enforces
    /// (`^[0-9A-HJKMNP-TV-Z]{26}$`) — duplicated here (rather than reused,
    /// since `DiaryClient`'s copy is private to that file) for
    /// `acceptRelayedKey` to validate an attacker-controlled `diaryId`
    /// BEFORE it's used to build a file path.
    private static let diaryIdPattern = "^[0-9A-HJKMNP-TV-Z]{26}$"

    // MARK: - Disk layout

    private func diaryDir(_ id: String) -> URL { directory.appendingPathComponent(id, isDirectory: true) }
    private func metaURL(_ id: String) -> URL { diaryDir(id).appendingPathComponent("meta.enc") }
    private func eventsLogURL(_ id: String) -> URL { diaryDir(id).appendingPathComponent("events.log") }
    private func pendingEventURL(_ id: String) -> URL { diaryDir(id).appendingPathComponent("pending.enc") }
    private func cursorURL(_ id: String) -> URL { diaryDir(id).appendingPathComponent("cursor.enc") }
    private var indexURL: URL { directory.appendingPathComponent("index.enc") }
    private var pendingCreateURL: URL { directory.appendingPathComponent("pending-create.enc") }

    /// The highest `seq` this device has confirmed via a CONTIGUOUS,
    /// paged `GET /events?since=` fetch (review round 1, C2) — deliberately
    /// NOT the event log's own `maxSeq`, which a write's own
    /// `sendPendingEvent` can push arbitrarily far ahead of what's
    /// actually been synced, opening a permanent gap. 0 (never synced)
    /// when no cursor file exists yet.
    private struct CursorFile: Codable { var syncedThrough: Int }

    private func readCursor(_ id: String) -> Int {
        guard let data = try? encryptor.readAndDecrypt(from: cursorURL(id)) else { return 0 }
        return (try? JSONDecoder().decode(CursorFile.self, from: data))?.syncedThrough ?? 0
    }

    private func writeCursor(_ id: String, _ value: Int) {
        do {
            try FileManager.default.createDirectory(at: diaryDir(id), withIntermediateDirectories: true)
            try encryptor.encryptAndWrite(JSONEncoder().encode(CursorFile(syncedThrough: value)), to: cursorURL(id))
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func readMeta(_ id: String) -> DiaryMeta? {
        guard let data = try? encryptor.readAndDecrypt(from: metaURL(id)) else { return nil }
        return try? JSONDecoder().decode(DiaryMeta.self, from: data)
    }

    private func persistMeta(_ id: String, _ meta: DiaryMeta) {
        do {
            try FileManager.default.createDirectory(at: diaryDir(id), withIntermediateDirectories: true)
            try encryptor.encryptAndWrite(JSONEncoder().encode(meta), to: metaURL(id))
        } catch {
            lastError = error.localizedDescription
        }
    }

    private struct IndexFile: Codable { var diaryIds: [String] }

    private func readIndex() -> [String] {
        guard let data = try? encryptor.readAndDecrypt(from: indexURL) else { return [] }
        return (try? JSONDecoder().decode(IndexFile.self, from: data))?.diaryIds ?? []
    }

    private func writeIndex(_ ids: [String]) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encryptor.encryptAndWrite(JSONEncoder().encode(IndexFile(diaryIds: ids)), to: indexURL)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func addToIndex(_ id: String) {
        var ids = readIndex()
        guard !ids.contains(id) else { return }
        ids.append(id)
        writeIndex(ids)
    }

    private func removeFromIndex(_ id: String) {
        var ids = readIndex()
        guard ids.contains(id) else { return }
        ids.removeAll { $0 == id }
        writeIndex(ids)
    }

    private struct PendingCreate: Codable { let diaryId: String; let name: String; let metaCipher: String }

    private func readPendingCreate() -> PendingCreate? {
        guard let data = try? encryptor.readAndDecrypt(from: pendingCreateURL) else { return nil }
        return try? JSONDecoder().decode(PendingCreate.self, from: data)
    }

    private func writePendingCreate(_ pending: PendingCreate) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encryptor.encryptAndWrite(JSONEncoder().encode(pending), to: pendingCreateURL)
    }

    private func clearPendingCreate() {
        try? FileManager.default.removeItem(at: pendingCreateURL)
    }

    private struct PendingEvent: Codable { let eventId: String; let type: DiaryEventType; let refSeq: Int?; let payloadCipher: String? }

    private func readPendingEvent(_ id: String) -> PendingEvent? {
        guard let data = try? encryptor.readAndDecrypt(from: pendingEventURL(id)) else { return nil }
        return try? JSONDecoder().decode(PendingEvent.self, from: data)
    }

    private func writePendingEvent(_ id: String, _ pending: PendingEvent) throws {
        try FileManager.default.createDirectory(at: diaryDir(id), withIntermediateDirectories: true)
        try encryptor.encryptAndWrite(JSONEncoder().encode(pending), to: pendingEventURL(id))
    }

    private func clearPendingEvent(_ id: String) {
        try? FileManager.default.removeItem(at: pendingEventURL(id))
    }
}

/// Serializes every `DiaryEventLog` read/append issued by `DiaryStore`
/// (across every diary — a coarser grain than "per diary", but still
/// correct, and simple: at most 20 diaries per account, so cross-diary
/// contention is not a real concern for the MVP) and, being an actor,
/// necessarily runs its (synchronous, non-suspending) method bodies off
/// whatever actor the caller was on — in particular, off `DiaryStore`'s
/// main actor. `DiaryEventLog` itself is cheap to construct (just an URL +
/// an encryptor reference), so a fresh instance per call is fine.
private actor DiaryLogCoordinator {
    private let encryptor: ChatDataEncryptor
    init(encryptor: ChatDataEncryptor) { self.encryptor = encryptor }

    @discardableResult
    func append(_ event: DiaryEvent, url: URL) -> Int? {
        try? DiaryEventLog(url: url, encryptor: encryptor).append(event)
    }

    func load(url: URL) -> DiaryEventLog.LoadResult {
        DiaryEventLog(url: url, encryptor: encryptor).load()
    }
}

/// Client-generated ULID (spec §0/§3.1/§5.1): a `diaryId` or event
/// `eventId`, 26 chars from the worker's own alphabet (`notes.ts`'s
/// `ULID_ALPHABET`, identical to `AccountID.alphabet`) — 10 timestamp
/// chars (ms since epoch, big-endian base32) + 16 random chars, matching
/// `DiaryClient`'s own `^[0-9A-HJKMNP-TV-Z]{26}$` shape check.
enum DiaryULID {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func generate(now: Date = Date()) -> String {
        var t = UInt64(max(0, now.timeIntervalSince1970 * 1000))
        var timeChars = [Character](repeating: "0", count: 10)
        for i in stride(from: 9, through: 0, by: -1) {
            timeChars[i] = alphabet[Int(t % 32)]
            t /= 32
        }
        var randomBytes = [UInt8](repeating: 0, count: 16)
        // Check the actual status (review round 1, minor) instead of
        // ignoring it — `SecRandomCopyBytes` CAN fail (however rarely), and
        // silently proceeding with an all-zero buffer would collapse every
        // id minted in the same millisecond to the same random suffix.
        let status = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        if status != errSecSuccess {
            var rng = SystemRandomNumberGenerator()
            for i in randomBytes.indices { randomBytes[i] = UInt8.random(in: 0...255, using: &rng) }
        }
        let randomChars = randomBytes.map { alphabet[Int($0) % 32] }
        return String(timeChars) + String(randomChars)
    }
}
