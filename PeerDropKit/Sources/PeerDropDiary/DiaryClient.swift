import Foundation
import PeerDropAccount
import PeerDropNotes

/// HTTP client for the worker's `/v3/diaries*` routes (spec §2.3), mirrored
/// from `cloudflare-worker/src/diary.ts`. Wraps an `AccountClient` for its
/// auth/401-retry plumbing, exactly like `NotesClient`. Every throwing call
/// maps `AccountClientError` down to a `DiaryError` via the worker's body
/// `error` code (`DiaryError.from`, below) — callers never see
/// `AccountClientError` directly.
public actor DiaryClient {
    private let account: AccountClient

    public init(account: AccountClient = AccountClient()) {
        self.account = account
    }

    // MARK: - Diary lifecycle

    /// `POST /v3/diaries {diaryId, metaCipher}` → 201 (new) or 200
    /// (idempotent re-create by the same owner) `{diaryId, inviteCode}`.
    /// `diaryId` must already be a client-generated 26-char ULID (spec
    /// §0) — this call does not generate one.
    public func create(diaryId: String, metaCipher: String) async throws -> (diaryId: String, inviteCode: String) {
        struct Body: Encodable { let diaryId: String; let metaCipher: String }
        struct R: Decodable { let diaryId: String; let inviteCode: String }
        do {
            let r: R = try await account.request("POST", "v3/diaries", body: Body(diaryId: diaryId, metaCipher: metaCipher))
            return (r.diaryId, r.inviteCode)
        } catch { throw DiaryError.from(error) }
    }

    /// `GET /v3/diaries` → this account's diary list (creation order).
    public func list() async throws -> [DiarySummary] {
        struct R: Decodable { let diaryId: String; let joinedAt: Int }
        do {
            let rows: [R] = try await account.request("GET", "v3/diaries", body: Optional<EmptyBody>.none)
            return rows.map { DiarySummary(diaryId: $0.diaryId, joinedAt: Date(timeIntervalSince1970: Double($0.joinedAt) / 1000)) }
        } catch { throw DiaryError.from(error) }
    }

    /// `GET /v3/diaries/:id` — the turn-order/meta source of truth (spec
    /// §5.1); current-member-only, `inviteCode` present only when the
    /// caller is the owner.
    public func get(_ id: String) async throws -> DiaryMeta {
        do {
            let r: GetMetaResponse = try await account.request("GET", "v3/diaries/\(id)", body: Optional<EmptyBody>.none)
            return r.asMeta
        } catch { throw DiaryError.from(error) }
    }

    /// `POST /v3/diaries/:id/join {inviteCode}` — join via a link (id
    /// already known, code carried in the URL fragment).
    public func join(id: String, code: String) async throws -> DiaryMeta {
        do {
            let r: JoinResponse = try await account.request("POST", "v3/diaries/\(id)/join", body: JoinRequestBody(inviteCode: code))
            return r.asMeta
        } catch { throw DiaryError.from(error) }
    }

    /// `POST /v3/diaries/join {inviteCode}` — join by short code alone
    /// (the worker resolves `diaryId` via D1 `diary_invites`).
    public func joinByCode(_ code: String) async throws -> DiaryMeta {
        do {
            let r: JoinResponse = try await account.request("POST", "v3/diaries/join", body: JoinRequestBody(inviteCode: code))
            return r.asMeta
        } catch { throw DiaryError.from(error) }
    }

    /// `POST /v3/diaries/:id/leave` → 204.
    public func leave(_ id: String) async throws {
        do {
            let _: EmptyBody = try await account.request("POST", "v3/diaries/\(id)/leave", body: Optional<EmptyBody>.none)
        } catch { throw DiaryError.from(error) }
    }

    /// `POST /v3/diaries/:id/close` → 204, owner-only.
    public func close(_ id: String) async throws {
        do {
            let _: EmptyBody = try await account.request("POST", "v3/diaries/\(id)/close", body: Optional<EmptyBody>.none)
        } catch { throw DiaryError.from(error) }
    }

    /// `POST /v3/diaries/:id/invite/reset` → `{inviteCode}`, owner-only.
    /// Invalidates the previous code; the diary key itself is unaffected.
    public func resetInvite(_ id: String) async throws -> String {
        struct R: Decodable { let inviteCode: String }
        do {
            let r: R = try await account.request("POST", "v3/diaries/\(id)/invite/reset", body: Optional<EmptyBody>.none)
            return r.inviteCode
        } catch { throw DiaryError.from(error) }
    }

    // MARK: - Events

    /// `GET /v3/diaries/:id/events?since=&limit=` — `since` is EXCLUSIVE
    /// (spec §0: "since 不含該序號"); current-member-only.
    public func events(id: String, since: Int, limit: Int = 100) async throws -> (events: [DiaryEvent], nextSince: Int?) {
        do {
            let r: EventsPageResponse = try await account.request("GET", "v3/diaries/\(id)/events?since=\(since)&limit=\(limit)", body: Optional<EmptyBody>.none)
            return (r.events.map(\.asEvent), r.nextSince)
        } catch { throw DiaryError.from(error) }
    }

    /// `POST /v3/diaries/:id/events {eventId, type, refSeq?, payloadCipher?}`
    /// → `{seq, holderIndex}`, decoded the same way whether the event was
    /// freshly created (201) or the POST was an idempotent resend (200 —
    /// exact `eventId` replay, or a repeat `like` on the same entry by the
    /// same account).
    public func postEvent(id: String, eventId: String, type: DiaryEventType, refSeq: Int? = nil, payloadCipher: String? = nil) async throws -> (seq: Int, holderIndex: Int) {
        struct Body: Encodable { let eventId: String; let type: DiaryEventType; let refSeq: Int?; let payloadCipher: String? }
        struct R: Decodable { let seq: Int; let holderIndex: Int }
        do {
            let r: R = try await account.request(
                "POST", "v3/diaries/\(id)/events",
                body: Body(eventId: eventId, type: type, refSeq: refSeq, payloadCipher: payloadCipher)
            )
            return (r.seq, r.holderIndex)
        } catch { throw DiaryError.from(error) }
    }

    /// A single event by `seq`. The worker does NOT expose
    /// `GET /v3/diaries/:id/events/:seq` — `diary.ts`'s `handleDiaryRoute`
    /// only calls the DO's internal `/event/:seq` for its own push/report
    /// lookups, never as a public route. Implemented here via the list
    /// route instead: `since: seq - 1, limit: 1` returns exactly the event
    /// at `seq` (since is exclusive and seq starts at 1, so `seq - 1` is a
    /// valid `since` even for `seq == 1`).
    public func event(id: String, seq: Int) async throws -> DiaryEvent {
        let (events, _) = try await events(id: id, since: seq - 1, limit: 1)
        guard let match = events.first(where: { $0.seq == seq }) else {
            throw DiaryError.network("not_found")
        }
        return match
    }

    /// `POST /v3/diaries/:id/request-key` → 204. Current-member-only;
    /// fans out a SILENT `diaryKeyRequest` push to the diary's other
    /// members (spec §3.3 step 1/§4) — never a visible notification.
    public func requestKey(_ id: String) async throws {
        do {
            let _: EmptyBody = try await account.request("POST", "v3/diaries/\(id)/request-key", body: Optional<EmptyBody>.none)
        } catch { throw DiaryError.from(error) }
    }

    /// `POST /v3/diaries/:id/events/:seq/report {reason, excerpt?}` → 201
    /// `{id}`. Reuses `PeerDropNotes.ReportReason` — same three values
    /// (`spam`/`harassment`/`other`) the worker accepts for both notes and
    /// diary reports.
    public func report(id: String, seq: Int, reason: ReportReason, excerpt: String?) async throws -> String {
        struct Body: Encodable { let reason: ReportReason; let excerpt: String? }
        struct R: Decodable { let id: String }
        do {
            let r: R = try await account.request("POST", "v3/diaries/\(id)/events/\(seq)/report", body: Body(reason: reason, excerpt: excerpt))
            return r.id
        } catch { throw DiaryError.from(error) }
    }
}

// MARK: - Wire DTOs

/// `GET /v3/diaries/:id`'s response shape — the only one of the meta-
/// shaped responses that actually carries `keyEpoch` and (for the owner)
/// `inviteCode`.
private struct GetMetaResponse: Decodable {
    let diaryId: String
    let ownerAccountId: String
    let members: [String]
    let holderIndex: Int
    let seq: Int
    let state: String
    let keyEpoch: Int
    let metaCipher: String
    let inviteCode: String?

    var asMeta: DiaryMeta {
        DiaryMeta(diaryId: diaryId, ownerAccountId: ownerAccountId, members: members, holderIndex: holderIndex,
                  seq: seq, state: state, keyEpoch: keyEpoch, metaCipher: metaCipher, inviteCode: inviteCode)
    }
}

private struct JoinRequestBody: Encodable { let inviteCode: String }

/// Both join routes (`.../:id/join` and `.../join`) return this shape
/// (`diary.ts`'s `performJoin`) — notably WITHOUT `keyEpoch` or
/// `inviteCode`. `keyEpoch` is hardcoded to 1 when converting to
/// `DiaryMeta`: the MVP never rotates it (spec §0 — "不做金鑰輪換
/// （keyEpoch 固定 1）"), so a join response omitting the field carries no
/// information loss.
private struct JoinResponse: Decodable {
    let diaryId: String
    let members: [String]
    let holderIndex: Int
    let ownerAccountId: String
    let state: String
    let seq: Int
    let metaCipher: String

    var asMeta: DiaryMeta {
        DiaryMeta(diaryId: diaryId, ownerAccountId: ownerAccountId, members: members, holderIndex: holderIndex,
                  seq: seq, state: state, keyEpoch: 1, metaCipher: metaCipher, inviteCode: nil)
    }
}

private struct WireEvent: Decodable {
    let seq: Int
    let eventId: String
    let type: DiaryEventType
    let authorAccountId: String
    let refSeq: Int?
    let payloadCipher: String?
    let createdAt: Int   // unix ms, per spec §2.3
    let skipped: String?

    var asEvent: DiaryEvent {
        DiaryEvent(seq: seq, eventId: eventId, type: type, authorAccountId: authorAccountId, refSeq: refSeq,
                   payloadCipher: payloadCipher, createdAt: Date(timeIntervalSince1970: Double(createdAt) / 1000), skipped: skipped)
    }
}

private struct EventsPageResponse: Decodable {
    let events: [WireEvent]
    let nextSince: Int?
}

// MARK: - Error mapping

extension DiaryError {
    /// Maps an `AccountClient` failure to a `DiaryError`, keyed off the
    /// worker's body `error` code (spec §0/§2.1) rather than the bare HTTP
    /// status — several distinct codes share a status (e.g. 403 covers
    /// `not_member`/`not_holder`/`not_owner`/`skip_self`/`diary_closed`/
    /// `bad_code`). A code this client doesn't have a named case for
    /// (`bad_type`, `bad_payload`, `missing_fields`, `invalid_id`,
    /// `d1_error`, `rate_limited`, a raw `not_found`, …) falls through to
    /// `.network(code)` so callers can still inspect it.
    static func from(_ error: Error) -> DiaryError {
        switch error {
        case AccountClientError.forbidden(let code):
            switch code {
            case "not_member": return .notMember
            case "not_holder": return .notHolder
            case "not_owner": return .notOwner
            case "skip_self": return .skipSelf
            case "diary_closed": return .closed
            case "bad_code": return .badCode
            default: return .network(code)
            }
        case AccountClientError.conflict(let code):
            switch code {
            case "diary_limit": return .limit
            case "diary_full_members": return .membersFull
            case "diary_exists": return .exists
            default: return .network(code)
            }
        case AccountClientError.invalid(let code):
            switch code {
            case "bad_ref": return .badRef
            case "too_large": return .tooLarge
            default: return .network(code)
            }
        case AccountClientError.insufficientStorage(let code):
            return code == "diary_full" ? .full : .network(code)
        case AccountClientError.rateLimited:
            return .network("rate_limited")
        case AccountClientError.http(let status):
            return .network("http_\(status)")
        case AccountClientError.unauthorized:
            return .network("unauthorized")
        case AccountClientError.invalidResponse:
            return .network("invalid_response")
        default:
            return .network(String(describing: error))
        }
    }
}
