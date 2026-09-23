import Foundation
import CryptoKit
import PeerDropSecurity
import PeerDropAccount
import PeerDropNotes

/// On-disk record of which `(diaryId, member)` pairs this device has
/// already successfully relayed its content key to, and when —
/// `<diaryId>/relayed.enc`, encrypted via `ChatDataEncryptor`. Fixes an
/// in-memory-only dedupe re-relaying (and burning an OPK) on every relaunch
/// (review round 1, I3). Plain synchronous methods — no actor of its own —
/// so `DiaryKeyRelay` can call them without an extra suspension point ahead
/// of its own in-flight guard.
public final class DiaryKeyRelayStore {
    private let directory: URL
    private let encryptor: ChatDataEncryptor

    public init(directory: URL, encryptor: ChatDataEncryptor) {
        self.directory = directory
        self.encryptor = encryptor
    }

    private struct RelayedFile: Codable { var members: [String: Date] }
    private func url(_ diaryId: String) -> URL {
        directory.appendingPathComponent(diaryId, isDirectory: true).appendingPathComponent("relayed.enc")
    }

    private func read(_ diaryId: String) -> [String: Date] {
        guard let data = try? encryptor.readAndDecrypt(from: url(diaryId)) else { return [:] }
        return (try? JSONDecoder().decode(RelayedFile.self, from: data))?.members ?? [:]
    }

    public func lastRelay(diaryId: String, member: String) -> Date? {
        read(diaryId)[member]
    }

    public func recordRelay(diaryId: String, member: String, at date: Date) {
        var members = read(diaryId)
        members[member] = date
        do {
            try FileManager.default.createDirectory(at: url(diaryId).deletingLastPathComponent(), withIntermediateDirectories: true)
            try encryptor.encryptAndWrite(JSONEncoder().encode(RelayedFile(members: members)), to: url(diaryId))
        } catch {
            // Best-effort: a failed write just means this relay might
            // repeat sooner than 24h next time — not worth surfacing as a
            // hard failure on an otherwise-successful send.
        }
    }
}

/// Short-code key hand-off (spec §3.3): once a new member has joined a
/// diary by short code alone, they have no content key. Every OTHER member
/// device that DOES hold a working key relays it to them the next time it
/// notices the new member's `join` event — driven entirely by
/// `DiaryStore.sync`, which calls `relayIfNeeded` once per un-relayed
/// `join` event it sees (§3.3 point 2). The 24h dedupe is persisted via
/// `relayStore` (review round 1, I3) so a relaunch doesn't re-relay to
/// every member it's already reached today.
///
/// `actor`-isolated: mutable state (the in-flight guard) can be touched
/// concurrently by `DiaryStore.sync(_:)` (per-diary, on every sync) and
/// `DiaryStore.handlePush(kind: "diaryKeyRequest", ...)` (force bypass) —
/// both `@MainActor` callers, so actor isolation here serializes access
/// without pulling this whole type onto the main actor.
public actor DiaryKeyRelay {
    private let notesClient: NotesClient
    private let crypto: NotesCryptoContext
    private let keyStore: DiaryKeyStore
    private let relayStore: DiaryKeyRelayStore
    private let now: () -> Date

    /// `(diaryId, member)` pairs with a send currently in progress —
    /// checked and inserted BEFORE the first `await` in `relayIfNeeded`, so
    /// two overlapping calls for the same pair can never both pass the
    /// dedupe check and both send (review round 1, I2). Cleared via
    /// `defer` on every exit path.
    private var inFlight: Set<String> = []
    private static let dedupeWindow: TimeInterval = 86_400

    public init(notesClient: NotesClient, crypto: NotesCryptoContext, keyStore: DiaryKeyStore, relayStore: DiaryKeyRelayStore, now: @escaping () -> Date = Date.init) {
        self.notesClient = notesClient
        self.crypto = crypto
        self.keyStore = keyStore
        self.relayStore = relayStore
        self.now = now
    }

    private static func dedupeKey(_ diaryId: String, _ member: String) -> String { "\(diaryId):\(member)" }

    /// Hands this device's diary content key to `newMember`, if — and only
    /// if — every one of these holds:
    /// - this device actually has a key saved for `diaryId`, AND
    /// - that key genuinely opens `metaCipher` (guards against relaying a
    ///   stale/wrong local key onward — spec §3.3 point 2's "本機有金鑰且
    ///   `openMeta` 成功"),
    /// - no send for this exact `(diaryId, newMember)` is already in
    ///   flight, AND
    /// - `force` is true, or the persisted 24h dedupe window for
    ///   `(diaryId, newMember)` has elapsed.
    ///
    /// `senderAccountId`/`senderNickname` are THIS device's own identity —
    /// the relay is always signed, never anonymous (spec §3.3 point 2:
    /// "signer: 必須署名"). Every failure (no key, wrong key, no directory
    /// bundle, PoW failure, a real 403 because this device turns out not to
    /// be a current member, a network error, …) is swallowed here: the
    /// caller (`DiaryStore.sync`) already knows to retry on the next round,
    /// and nothing about a failed attempt should ever look like a success to
    /// the rest of the system — critically, nothing is written to
    /// `relayStore` except on a 2xx from the server.
    ///
    /// The one 2xx this CANNOT distinguish is the worker's blocked-sender
    /// fake 201 (`notes.ts`, applied after the membership check): a member
    /// who has blocked this device never receives the key, yet the dedupe is
    /// written and suppresses retries for 24h. Deliberate — the fake 201
    /// exists precisely so a sender can't detect a block — see the spec's
    /// §6 實作差異 note; recovery is unblock + 「重新請求金鑰」, which
    /// arrives here as `force: true`.
    public func relayIfNeeded(
        diaryId: String, newMember: String, metaCipher: String,
        senderAccountId: String, senderNickname: String?, force: Bool = false
    ) async {
        guard let key = keyStore.key(for: diaryId) else { return }
        guard let cipherData = Data(base64Encoded: metaCipher),
              (try? DiaryCrypto.openMeta(cipherData, key: key, diaryId: diaryId, keyEpoch: 1)) != nil
        else { return }

        let dedupeKey = Self.dedupeKey(diaryId, newMember)
        // Both checks below run synchronously (no `await` yet reached in
        // this call), so they and the `inFlight` insert happen atomically
        // with respect to any other task queued on this actor — that's
        // what makes the in-flight guard actually race-free.
        guard !inFlight.contains(dedupeKey) else { return }
        if !force, let last = relayStore.lastRelay(diaryId: diaryId, member: newMember), now().timeIntervalSince(last) < Self.dedupeWindow {
            return
        }
        inFlight.insert(dedupeKey)
        defer { inFlight.remove(dedupeKey) }

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
            relayStore.recordRelay(diaryId: diaryId, member: newMember, at: now())
        } catch {
            // No dedupe write on any failure — see the doc comment above.
        }
    }
}
