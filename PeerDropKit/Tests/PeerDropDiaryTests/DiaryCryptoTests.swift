import XCTest
import CryptoKit
@testable import PeerDropDiary

final class DiaryCryptoTests: XCTestCase {
    private let key = SymmetricKey(size: .bits256)

    func testSealOpenRoundTrip() throws {
        let payload = DiaryPayload(kind: .entry, text: "今天天氣真好")
        let sealed = try DiaryCrypto.seal(payload: payload, key: key, diaryId: "D1", authorAccountId: "A1", eventId: "E1", maxScalars: DiaryCrypto.maxEntryScalars)
        let opened = try DiaryCrypto.open(sealed, key: key, diaryId: "D1", authorAccountId: "A1", eventId: "E1", maxScalars: DiaryCrypto.maxEntryScalars)
        XCTAssertEqual(opened, payload)
    }

    /// Manually slices `nonce(12) ‖ ciphertext ‖ tag(16)` out of the sealed
    /// blob and reconstructs a `CryptoKit.AES.GCM.SealedBox` directly
    /// (bypassing `DiaryCrypto.open` entirely) — proves the byte layout
    /// really is that shape, rather than just asserting a total length.
    func testSealedBlobIsNonceCiphertextTag() throws {
        let payload = DiaryPayload(kind: .comment, text: "hi")
        let sealed = try DiaryCrypto.seal(payload: payload, key: key, diaryId: "D1", authorAccountId: "A1", eventId: "E1", maxScalars: DiaryCrypto.maxCommentScalars)
        XCTAssertGreaterThan(sealed.count, 12 + 16)

        let nonceData = sealed.prefix(12)
        let tag = sealed.suffix(16)
        let ciphertext = sealed.dropFirst(12).dropLast(16)
        let aad = Data("D1".utf8) + Data("A1".utf8) + Data("E1".utf8)
        let box = try AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: nonceData), ciphertext: ciphertext, tag: tag)
        let plaintext = try AES.GCM.open(box, using: key, authenticating: aad)
        let decoded = try JSONDecoder().decode(DiaryPayload.self, from: plaintext)
        XCTAssertEqual(decoded, payload)
    }

    func testOpenFailsWhenDiaryIdDiffers() throws {
        let payload = DiaryPayload(kind: .entry, text: "x")
        let sealed = try DiaryCrypto.seal(payload: payload, key: key, diaryId: "D1", authorAccountId: "A1", eventId: "E1", maxScalars: DiaryCrypto.maxEntryScalars)
        XCTAssertThrowsError(try DiaryCrypto.open(sealed, key: key, diaryId: "D2", authorAccountId: "A1", eventId: "E1", maxScalars: DiaryCrypto.maxEntryScalars)) {
            XCTAssertEqual($0 as? DiaryCryptoError, .decryptionFailed)
        }
    }

    func testOpenFailsWhenAuthorAccountIdDiffers() throws {
        let payload = DiaryPayload(kind: .entry, text: "x")
        let sealed = try DiaryCrypto.seal(payload: payload, key: key, diaryId: "D1", authorAccountId: "A1", eventId: "E1", maxScalars: DiaryCrypto.maxEntryScalars)
        XCTAssertThrowsError(try DiaryCrypto.open(sealed, key: key, diaryId: "D1", authorAccountId: "A2", eventId: "E1", maxScalars: DiaryCrypto.maxEntryScalars)) {
            XCTAssertEqual($0 as? DiaryCryptoError, .decryptionFailed)
        }
    }

    func testOpenFailsWhenEventIdDiffers() throws {
        let payload = DiaryPayload(kind: .entry, text: "x")
        let sealed = try DiaryCrypto.seal(payload: payload, key: key, diaryId: "D1", authorAccountId: "A1", eventId: "E1", maxScalars: DiaryCrypto.maxEntryScalars)
        XCTAssertThrowsError(try DiaryCrypto.open(sealed, key: key, diaryId: "D1", authorAccountId: "A1", eventId: "E2", maxScalars: DiaryCrypto.maxEntryScalars)) {
            XCTAssertEqual($0 as? DiaryCryptoError, .decryptionFailed)
        }
    }

    func testOpenFailsWithWrongKey() throws {
        let payload = DiaryPayload(kind: .entry, text: "x")
        let sealed = try DiaryCrypto.seal(payload: payload, key: key, diaryId: "D1", authorAccountId: "A1", eventId: "E1", maxScalars: DiaryCrypto.maxEntryScalars)
        let wrongKey = SymmetricKey(size: .bits256)
        XCTAssertThrowsError(try DiaryCrypto.open(sealed, key: wrongKey, diaryId: "D1", authorAccountId: "A1", eventId: "E1", maxScalars: DiaryCrypto.maxEntryScalars)) {
            XCTAssertEqual($0 as? DiaryCryptoError, .decryptionFailed)
        }
    }

    func testTamperedCiphertextFailsToOpen() throws {
        let payload = DiaryPayload(kind: .entry, text: "x")
        var sealed = try DiaryCrypto.seal(payload: payload, key: key, diaryId: "D1", authorAccountId: "A1", eventId: "E1", maxScalars: DiaryCrypto.maxEntryScalars)
        // Flip a byte inside the ciphertext region (after the 12-byte nonce).
        sealed[12] ^= 0xFF
        XCTAssertThrowsError(try DiaryCrypto.open(sealed, key: key, diaryId: "D1", authorAccountId: "A1", eventId: "E1", maxScalars: DiaryCrypto.maxEntryScalars)) {
            XCTAssertEqual($0 as? DiaryCryptoError, .decryptionFailed)
        }
    }

    func testTruncatedBlobFailsToOpen() {
        XCTAssertThrowsError(try DiaryCrypto.open(Data([1, 2, 3]), key: key, diaryId: "D1", authorAccountId: "A1", eventId: "E1", maxScalars: DiaryCrypto.maxEntryScalars)) {
            XCTAssertEqual($0 as? DiaryCryptoError, .decryptionFailed)
        }
    }

    /// `seal` enforces the same limit `open` does — a caller can't produce
    /// an oversized ciphertext in the first place.
    func testSealRejectsOversizedText() {
        let longText = String(repeating: "字", count: DiaryCrypto.maxEntryScalars + 1)
        let payload = DiaryPayload(kind: .entry, text: longText)
        XCTAssertThrowsError(try DiaryCrypto.seal(payload: payload, key: key, diaryId: "D1", authorAccountId: "A1", eventId: "E1", maxScalars: DiaryCrypto.maxEntryScalars)) {
            XCTAssertEqual($0 as? DiaryCryptoError, .oversized)
        }
    }

    /// `open`'s own scalar check is independent of `seal`'s — simulates a
    /// ciphertext that reached `open` despite being oversized (e.g. sealed
    /// under a different/looser limit) and confirms `open` still rejects it
    /// rather than trusting that nothing oversized could ever arrive.
    func testOpenRejectsOversizedTextEvenIfSealedUnderALargerLimit() throws {
        let longText = String(repeating: "字", count: DiaryCrypto.maxEntryScalars + 1)
        let payload = DiaryPayload(kind: .entry, text: longText)
        let sealed = try DiaryCrypto.seal(payload: payload, key: key, diaryId: "D1", authorAccountId: "A1", eventId: "E1", maxScalars: longText.unicodeScalars.count)
        XCTAssertThrowsError(try DiaryCrypto.open(sealed, key: key, diaryId: "D1", authorAccountId: "A1", eventId: "E1", maxScalars: DiaryCrypto.maxEntryScalars)) {
            XCTAssertEqual($0 as? DiaryCryptoError, .oversized)
        }
    }

    func testOversizedCommentUsesTheSmallerLimit() throws {
        let text = String(repeating: "字", count: DiaryCrypto.maxCommentScalars + 1)
        let payload = DiaryPayload(kind: .comment, text: text)
        // Under the entry limit (so `seal` itself allows it through) but
        // over the comment limit.
        XCTAssertLessThan(DiaryCrypto.maxCommentScalars + 1, DiaryCrypto.maxEntryScalars)
        let sealed = try DiaryCrypto.seal(payload: payload, key: key, diaryId: "D1", authorAccountId: "A1", eventId: "E1", maxScalars: DiaryCrypto.maxEntryScalars)
        XCTAssertThrowsError(try DiaryCrypto.open(sealed, key: key, diaryId: "D1", authorAccountId: "A1", eventId: "E1", maxScalars: DiaryCrypto.maxCommentScalars)) {
            XCTAssertEqual($0 as? DiaryCryptoError, .oversized)
        }
    }

    func testMetaSealOpenRoundTrip() throws {
        let sealed = try DiaryCrypto.sealMeta(name: "我們的日記", key: key, diaryId: "D1", keyEpoch: 1)
        let name = try DiaryCrypto.openMeta(sealed, key: key, diaryId: "D1", keyEpoch: 1)
        XCTAssertEqual(name, "我們的日記")
    }

    func testMetaOpenFailsWhenKeyEpochDiffers() throws {
        let sealed = try DiaryCrypto.sealMeta(name: "N", key: key, diaryId: "D1", keyEpoch: 1)
        XCTAssertThrowsError(try DiaryCrypto.openMeta(sealed, key: key, diaryId: "D1", keyEpoch: 2)) {
            XCTAssertEqual($0 as? DiaryCryptoError, .decryptionFailed)
        }
    }

    func testMetaOpenFailsWhenDiaryIdDiffers() throws {
        let sealed = try DiaryCrypto.sealMeta(name: "N", key: key, diaryId: "D1", keyEpoch: 1)
        XCTAssertThrowsError(try DiaryCrypto.openMeta(sealed, key: key, diaryId: "D2", keyEpoch: 1)) {
            XCTAssertEqual($0 as? DiaryCryptoError, .decryptionFailed)
        }
    }

    /// A diary's content key and its meta AEAD are cross-domain-separated —
    /// an entry payload sealed for an event must not open as meta, even
    /// under the same key/diaryId.
    func testEntrySealCannotBeOpenedAsMeta() throws {
        let payload = DiaryPayload(kind: .entry, text: "x")
        let sealed = try DiaryCrypto.seal(payload: payload, key: key, diaryId: "D1", authorAccountId: "meta", eventId: "1", maxScalars: DiaryCrypto.maxEntryScalars)
        XCTAssertThrowsError(try DiaryCrypto.openMeta(sealed, key: key, diaryId: "D1", keyEpoch: 1))
    }

    // MARK: - Frozen regression vectors (spec §3.1)
    //
    // Generated ONCE with a literal 32-byte key, literal diaryId "D1" /
    // authorAccountId "A1" / eventId "E1", and literal plaintext, then
    // pasted here. `seal` uses a fresh random nonce every call, so a live
    // round-trip test alone can't catch a future refactor that silently
    // changes the nonce‖ct‖tag layout, the AAD field order, or the meta
    // `keyEpoch` big-endian width — these frozen blobs must go on
    // decrypting to the same values forever.

    private static let frozenKey = SymmetricKey(data: Data(base64Encoded: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=")!)

    func testFrozenPayloadCipherVectorStillDecrypts() throws {
        let payloadCipher = Data(base64Encoded: "mwhixIQsr6pVugXaqgB2E7NmRXEq9OrnAuaxDhyGbhSJzCfdQXLFcsYTAF0fEw51wnz7dysj/U2oRlURWPkY29E2hA==")!
        let payload = try DiaryCrypto.open(payloadCipher, key: Self.frozenKey, diaryId: "D1", authorAccountId: "A1", eventId: "E1", maxScalars: DiaryCrypto.maxEntryScalars)
        XCTAssertEqual(payload, DiaryPayload(kind: .entry, text: "frozen vector"))
    }

    func testFrozenMetaCipherVectorStillDecrypts() throws {
        let metaCipher = Data(base64Encoded: "mk6FYZoCpVmuPTeoZGLmKwflnufn6K3fPeFKghvVUQNq3vA18jRIdpeec2esoImJqYdw")!
        let name = try DiaryCrypto.openMeta(metaCipher, key: Self.frozenKey, diaryId: "D1", keyEpoch: 1)
        XCTAssertEqual(name, "Frozen Diary")
    }
}
