import Foundation
import CryptoKit

public enum DiaryCryptoError: Error, Equatable {
    /// The decrypted plaintext decoded but its `text` exceeds `maxScalars`
    /// (5,000 for `entry`, 500 for `comment` — spec §3.1). The caller
    /// should discard this event ("內容無法顯示"), not retry.
    case oversized
    case decryptionFailed
    case malformedPlaintext
}

/// Pure functions for a diary's content encryption (spec §3.1) — no I/O,
/// no singletons, safe to call from any thread/actor.
///
/// AES-256-GCM. AAD binds a payload to exactly the event it was sealed
/// for: `utf8(diaryId) ‖ utf8(authorAccountId) ‖ utf8(eventId)` for
/// entries/comments, `utf8(diaryId) ‖ utf8("meta") ‖ keyEpoch (UInt32 BE)`
/// for the diary's name. `seal`/`sealMeta` return raw `nonce(12) ‖
/// ciphertext ‖ tag(16)` — callers (`DiaryClient`/`DiaryStore`) base64
/// it for the wire.
public enum DiaryCrypto {
    public static let maxEntryScalars = 5_000
    public static let maxCommentScalars = 500
    static let nonceLength = 12
    static let tagLength = 16

    static func aad(diaryId: String, authorAccountId: String, eventId: String) -> Data {
        var d = Data(diaryId.utf8)
        d.append(Data(authorAccountId.utf8))
        d.append(Data(eventId.utf8))
        return d
    }

    static func metaAAD(diaryId: String, keyEpoch: UInt32) -> Data {
        var d = Data(diaryId.utf8)
        d.append(Data("meta".utf8))
        var be = keyEpoch.bigEndian
        d.append(Data(bytes: &be, count: 4))
        return d
    }

    private struct MetaPlaintext: Codable { let name: String }

    /// Enforces the same `maxScalars` limit `open` checks on the way back
    /// out — a caller that seals oversized text would otherwise only find
    /// out when SOME device later tries to open it and silently discards
    /// the event (spec §3.1's oversize rule is meant to reject at the
    /// source, not just at every reader).
    public static func seal(payload: DiaryPayload, key: SymmetricKey, diaryId: String, authorAccountId: String, eventId: String, maxScalars: Int) throws -> Data {
        guard payload.text.unicodeScalars.count <= maxScalars else { throw DiaryCryptoError.oversized }
        let plaintext = try JSONEncoder().encode(payload)
        return try seal(plaintext: plaintext, key: key, aad: aad(diaryId: diaryId, authorAccountId: authorAccountId, eventId: eventId))
    }

    /// Throws `DiaryCryptoError.decryptionFailed` for a malformed blob or a
    /// failed AEAD open (wrong key, tampered ciphertext, or any AAD field
    /// — `diaryId`/`authorAccountId`/`eventId` — not matching what it was
    /// sealed with), `.malformedPlaintext` when the opened bytes aren't a
    /// valid `DiaryPayload`, and `.oversized` when they are but exceed
    /// `maxScalars`.
    public static func open(_ data: Data, key: SymmetricKey, diaryId: String, authorAccountId: String, eventId: String, maxScalars: Int) throws -> DiaryPayload {
        let plaintext = try open(cipher: data, key: key, aad: aad(diaryId: diaryId, authorAccountId: authorAccountId, eventId: eventId))
        guard let payload = try? JSONDecoder().decode(DiaryPayload.self, from: plaintext) else {
            throw DiaryCryptoError.malformedPlaintext
        }
        guard payload.text.unicodeScalars.count <= maxScalars else { throw DiaryCryptoError.oversized }
        return payload
    }

    public static func sealMeta(name: String, key: SymmetricKey, diaryId: String, keyEpoch: UInt32) throws -> Data {
        let plaintext = try JSONEncoder().encode(MetaPlaintext(name: name))
        return try seal(plaintext: plaintext, key: key, aad: metaAAD(diaryId: diaryId, keyEpoch: keyEpoch))
    }

    public static func openMeta(_ data: Data, key: SymmetricKey, diaryId: String, keyEpoch: UInt32) throws -> String {
        let plaintext = try open(cipher: data, key: key, aad: metaAAD(diaryId: diaryId, keyEpoch: keyEpoch))
        guard let decoded = try? JSONDecoder().decode(MetaPlaintext.self, from: plaintext) else {
            throw DiaryCryptoError.malformedPlaintext
        }
        return decoded.name
    }

    // MARK: - Shared AEAD plumbing

    private static func seal(plaintext: Data, key: SymmetricKey, aad: Data) throws -> Data {
        let nonce = AES.GCM.Nonce()
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        // `.ciphertext`/`.tag` are slices into the sealed box's combined
        // representation and can carry non-zero start indices — normalize
        // through `Data(...)` before appending (same reasoning as
        // `NoteCrypto.seal`).
        var out = Data(nonce)
        out.append(Data(box.ciphertext))
        out.append(box.tag)
        return out
    }

    private static func open(cipher data: Data, key: SymmetricKey, aad: Data) throws -> Data {
        guard data.count >= nonceLength + tagLength else { throw DiaryCryptoError.decryptionFailed }
        let nonceData = Data(data.prefix(nonceLength))
        let ciphertext = Data(data.dropFirst(nonceLength).dropLast(tagLength))
        let tag = Data(data.suffix(tagLength))
        do {
            let box = try AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: nonceData), ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(box, using: key, authenticating: aad)
        } catch {
            throw DiaryCryptoError.decryptionFailed
        }
    }
}
