import Foundation
import CryptoKit
import PeerDropSecurity

/// One 32-byte diary content key per diary — `Documents/Diary/<diaryId>/key.enc`
/// (spec §3.5), encrypted at rest via `ChatDataEncryptor`. A key is only
/// ever written after `DiaryCrypto.openMeta` has verified it against the
/// diary's `metaCipher` (spec §3.2/§3.3) — this store itself does no such
/// verification; it is pure key-material persistence.
public final class DiaryKeyStore {
    public let directory: URL
    public let encryptor: ChatDataEncryptor

    public init(directory: URL? = nil, encryptor: ChatDataEncryptor = .shared) {
        self.directory = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Diary", isDirectory: true)
        self.encryptor = encryptor
    }

    private func keyURL(for diaryId: String) -> URL {
        directory.appendingPathComponent(diaryId, isDirectory: true).appendingPathComponent("key.enc")
    }

    /// nil when no key has been saved for this diary yet, or the stored
    /// bytes are unreadable/not exactly 32 bytes.
    public func key(for diaryId: String) -> SymmetricKey? {
        guard let data = try? encryptor.readAndDecrypt(from: keyURL(for: diaryId)), data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    /// Writes the key atomically (`ChatDataEncryptor.encryptAndWrite` uses
    /// `Data.write(options: .atomic)`), replacing any previously-saved key
    /// for this diary.
    public func save(key: SymmetricKey, for diaryId: String) throws {
        let url = keyURL(for: diaryId)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encryptor.encryptAndWrite(key.withUnsafeBytes { Data($0) }, to: url)
    }

    /// Removes a diary's key (e.g. the diary was deleted/left and its
    /// content should no longer be readable going forward). A no-op if no
    /// key was ever saved.
    public func removeKey(for diaryId: String) throws {
        let url = keyURL(for: diaryId)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
