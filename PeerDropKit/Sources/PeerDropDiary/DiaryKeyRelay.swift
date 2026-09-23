import Foundation
import CryptoKit
import PeerDropAccount
import PeerDropNotes

/// Short-code key hand-off (spec §3.3): once a new member has joined a
/// diary by short code alone, they have no content key. Every OTHER member
/// device that DOES hold a working key relays it to them the next time it
/// notices the new member's `join` event — driven entirely by
/// `DiaryStore.sync`, which calls `relayIfNeeded` once per un-relayed
/// `join` event it sees (§3.3 point 2). There is no persisted "already
/// relayed" bookkeeping on the `DiaryStore` side — the 24h dedupe here is
/// the only thing standing between "harmless repeat relay" and "OPK spam",
/// and it is intentionally in-memory/per-process (a relaunch simply
/// refetches/retries, same as `DirectoryCache`).
///
/// `actor`-isolated: the dedupe cache is mutable state that can be touched
/// concurrently by `DiaryStore.sync(_:)` (per-diary, on every sync) and
/// `DiaryStore.handlePush(kind: "diaryKeyRequest", ...)` (force bypass) —
/// both `@MainActor` callers, so actor isolation here serializes access to
/// the cache without pulling this whole type onto the main actor.
public actor DiaryKeyRelay {
    private let notesClient: NotesClient
    private let crypto: NotesCryptoContext
    private let keyStore: DiaryKeyStore
    private let now: () -> Date

    /// `"<diaryId>:<member>"` → the moment of the last SUCCESSFUL (server
    /// accepted) relay send. Written ONLY after `notesClient.send` actually
    /// returns — never on a blocked/failed attempt (spec §3.3 point 4:
    /// "去重鍵只在 POST 真正 201 後寫入"). That is what makes a worker-side
    /// 403 (a caller that turns out not to be a member after all) or any
    /// other failure retry-able on the very next sync instead of being
    /// silently suppressed for a day.
    private var lastSuccess: [String: Date] = [:]
    private static let dedupeWindow: TimeInterval = 86_400

    public init(notesClient: NotesClient, crypto: NotesCryptoContext, keyStore: DiaryKeyStore, now: @escaping () -> Date = Date.init) {
        self.notesClient = notesClient
        self.crypto = crypto
        self.keyStore = keyStore
        self.now = now
    }

    private static func dedupeKey(_ diaryId: String, _ member: String) -> String { "\(diaryId):\(member)" }

    /// Test/diagnostic hook only — not used by production relay logic,
    /// which never needs to ask "did I already send this" outside the
    /// dedupe check itself.
    func lastSuccessForTesting(diaryId: String, member: String) -> Date? {
        lastSuccess[Self.dedupeKey(diaryId, member)]
    }

    /// Hands this device's diary content key to `newMember`, if — and only
    /// if — every one of these holds:
    /// - this device actually has a key saved for `diaryId`, AND
    /// - that key genuinely opens `metaCipher` (guards against relaying a
    ///   stale/wrong local key onward — spec §3.3 point 2's "本機有金鑰且
    ///   `openMeta` 成功"),
    /// - `force` is true, or the 24h dedupe window for `(diaryId,
    ///   newMember)` has elapsed.
    ///
    /// `senderAccountId`/`senderNickname` are THIS device's own identity —
    /// the relay is always signed, never anonymous (spec §3.3 point 2:
    /// "signer: 必須署名"). Every failure (no key, wrong key, no directory
    /// bundle, PoW failure, a real 403 because this device turns out not to
    /// be a current member, a network error, …) is swallowed here: the
    /// caller (`DiaryStore.sync`) already knows to retry on the next round,
    /// and nothing about a failed attempt should ever look like a "fake
    /// 201" to the rest of the system (spec §6: "封鎖造成的假 201 不會出
    /// 現").
    public func relayIfNeeded(
        diaryId: String, newMember: String, metaCipher: String,
        senderAccountId: String, senderNickname: String?, force: Bool = false
    ) async {
        guard let key = keyStore.key(for: diaryId) else { return }
        guard let cipherData = Data(base64Encoded: metaCipher),
              (try? DiaryCrypto.openMeta(cipherData, key: key, diaryId: diaryId, keyEpoch: 1)) != nil
        else { return }

        let dedupeKey = Self.dedupeKey(diaryId, newMember)
        if !force, let last = lastSuccess[dedupeKey], now().timeIntervalSince(last) < Self.dedupeWindow {
            return
        }

        guard let entry = try? await notesClient.lookup(handle: newMember, includeBundle: true), entry.preKeyBundle != nil else { return }

        struct RelayPayload: Encodable { let diaryId: String; let keyEpoch: UInt32; let key: String }
        let payload = RelayPayload(diaryId: diaryId, keyEpoch: 1, key: key.withUnsafeBytes { Data($0) }.base64EncodedString())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let payloadData = try? encoder.encode(payload), let text = String(data: payloadData, encoding: .utf8) else { return }

        do {
            let signer = try crypto.signer(accountId: senderAccountId, nickname: senderNickname)
            let envelope = try NoteCrypto.seal(text: text, recipient: entry, signer: signer, kind: .diaryKey)
            let bytes = try envelope.wireBytes()
            let challenge = try await notesClient.powChallenge()
            guard let nonce = await NoteProofOfWork.solve(challenge: challenge, recipientAccountId: entry.accountId.raw, envelopeBytes: bytes) else { return }
            _ = try await notesClient.send(to: entry.accountId.raw, envelopeBase64: bytes.base64EncodedString(), challenge: challenge, nonce: nonce, kind: "diaryKey", diaryId: diaryId)
            lastSuccess[dedupeKey] = now()
        } catch {
            // No dedupe write on any failure — see the doc comment above.
        }
    }
}
