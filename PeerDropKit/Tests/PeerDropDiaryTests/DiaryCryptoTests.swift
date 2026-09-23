import XCTest
import CryptoKit
@testable import PeerDropDiary

final class DiaryCryptoTests: XCTestCase {
    private let key = SymmetricKey(size: .bits256)

    func testSealOpenRoundTrip() throws {
        let payload = DiaryPayload(kind: .entry, text: "今天天氣真好")
        let sealed = try DiaryCrypto.seal(payload: payload, key: key, diaryId: "D1", authorAccountId: "A1", eventId: "E1")
        let opened = try DiaryCrypto.open(sealed, key: key, diaryId: "D1", authorAccountId: "A1", eventId: "E1", maxScalars: DiaryCrypto.maxEntryScalars)
        XCTAssertEqual(opened, payload)
    }

    func testSealedBlobIsNonceCiphertextTag() throws {
        let payload = DiaryPayload(kind: .comment, text: "hi")
        let sealed = try DiaryCrypto.seal(payload: payload, key: key, diaryId: "D1", authorAccountId: "A1", eventId: "E1")
        // nonce(12) + ciphertext(>=1, JSON plaintext is non-empty) + tag(16)
        XCTAssertGreaterThan(sealed.count, 12 + 16)
    }

    func testOpenFailsWhenDiaryIdDiffers() throws {
        let payload = DiaryPayload(kind: .entry, text: "x")
        let sealed = try DiaryCrypto.seal(payload: payload, key: key, diaryId: "D1", authorAccountId: "A1", eventId: "E1")
        XCTAssertThrowsError(try DiaryCrypto.open(sealed, key: key, diaryId: "D2", authorAccountId: "A1", eventId: "E1", maxScalars: DiaryCrypto.maxEntryScalars)) {
            XCTAssertEqual($0 as? DiaryCryptoError, .decryptionFailed)
        }
    }

    func testOpenFailsWhenAuthorAccountIdDiffers() throws {
        let payload = DiaryPayload(kind: .entry, text: "x")
        let sealed = try DiaryCrypto.seal(payload: payload, key: key, diaryId: "D1", authorAccountId: "A1", eventId: "E1")
        XCTAssertThrowsError(try DiaryCrypto.open(sealed, key: key, diaryId: "D1", authorAccountId: "A2", eventId: "E1", maxScalars: DiaryCrypto.maxEntryScalars)) {
            XCTAssertEqual($0 as? DiaryCryptoError, .decryptionFailed)
        }
    }

    func testOpenFailsWhenEventIdDiffers() throws {
        let payload = DiaryPayload(kind: .entry, text: "x")
        let sealed = try DiaryCrypto.seal(payload: payload, key: key, diaryId: "D1", authorAccountId: "A1", eventId: "E1")
        XCTAssertThrowsError(try DiaryCrypto.open(sealed, key: key, diaryId: "D1", authorAccountId: "A1", eventId: "E2", maxScalars: DiaryCrypto.maxEntryScalars)) {
            XCTAssertEqual($0 as? DiaryCryptoError, .decryptionFailed)
        }
    }

    func testOpenFailsWithWrongKey() throws {
        let payload = DiaryPayload(kind: .entry, text: "x")
        let sealed = try DiaryCrypto.seal(payload: payload, key: key, diaryId: "D1", authorAccountId: "A1", eventId: "E1")
        let wrongKey = SymmetricKey(size: .bits256)
        XCTAssertThrowsError(try DiaryCrypto.open(sealed, key: wrongKey, diaryId: "D1", authorAccountId: "A1", eventId: "E1", maxScalars: DiaryCrypto.maxEntryScalars)) {
            XCTAssertEqual($0 as? DiaryCryptoError, .decryptionFailed)
        }
    }

    func testTamperedCiphertextFailsToOpen() throws {
        let payload = DiaryPayload(kind: .entry, text: "x")
        var sealed = try DiaryCrypto.seal(payload: payload, key: key, diaryId: "D1", authorAccountId: "A1", eventId: "E1")
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

    func testOversizedEntryTextIsRejected() throws {
        let longText = String(repeating: "字", count: DiaryCrypto.maxEntryScalars + 1)
        let payload = DiaryPayload(kind: .entry, text: longText)
        let sealed = try DiaryCrypto.seal(payload: payload, key: key, diaryId: "D1", authorAccountId: "A1", eventId: "E1")
        XCTAssertThrowsError(try DiaryCrypto.open(sealed, key: key, diaryId: "D1", authorAccountId: "A1", eventId: "E1", maxScalars: DiaryCrypto.maxEntryScalars)) {
            XCTAssertEqual($0 as? DiaryCryptoError, .oversized)
        }
    }

    func testOversizedCommentUsesTheSmallerLimit() throws {
        let text = String(repeating: "字", count: DiaryCrypto.maxCommentScalars + 1)
        let payload = DiaryPayload(kind: .comment, text: text)
        let sealed = try DiaryCrypto.seal(payload: payload, key: key, diaryId: "D1", authorAccountId: "A1", eventId: "E1")
        // Under the entry limit but over the comment limit.
        XCTAssertLessThan(DiaryCrypto.maxCommentScalars + 1, DiaryCrypto.maxEntryScalars)
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
        let sealed = try DiaryCrypto.seal(payload: payload, key: key, diaryId: "D1", authorAccountId: "meta", eventId: "1")
        XCTAssertThrowsError(try DiaryCrypto.openMeta(sealed, key: key, diaryId: "D1", keyEpoch: 1))
    }
}
