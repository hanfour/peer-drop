import Foundation
import CryptoKit
import Security

final class ChatDataEncryptor {
    static let shared = ChatDataEncryptor()

    private static let magic: [UInt8] = [0x50, 0x44, 0x45, 0x4B] // "PDEK"
    private static let formatVersion: UInt8 = 0x01
    private static let headerSize = 5   // 4 magic + 1 version
    private static let nonceSize = 12
    private static let tagSize = 16
    private static let overhead = headerSize + nonceSize + tagSize // 33

    private static let keychainService = "com.peerdrop.chatdata"
    private static let keychainAccount = "aes256-key"

    private var cachedKey: SymmetricKey?
    private let lock = NSLock()

    private init() {}

    // MARK: - Key Management

    func getOrCreateKey() throws -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }

        if let key = cachedKey { return key }

        if let existing = try loadKeyFromKeychain() {
            cachedKey = existing
            return existing
        }

        let newKey = SymmetricKey(size: .bits256)
        try saveKeyToKeychain(newKey)
        cachedKey = newKey
        return newKey
    }

    private func loadKeyFromKeychain() throws -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw EncryptionError.keychainError(status)
        }

        return SymmetricKey(data: data)
    }

    private func saveKeyToKeychain(_ key: SymmetricKey) throws {
        let keyData = key.withUnsafeBytes { Data($0) }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw EncryptionError.keychainError(status)
        }
    }

    // MARK: - Encrypt / Decrypt

    func encrypt(_ data: Data) throws -> Data {
        let key = try getOrCreateKey()
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(data, using: key, nonce: nonce)

        var result = Data(capacity: Self.overhead + data.count)
        result.append(contentsOf: Self.magic)
        result.append(Self.formatVersion)
        result.append(contentsOf: sealed.nonce)
        result.append(sealed.ciphertext)
        result.append(sealed.tag)
        return result
    }

    func decrypt(_ data: Data) throws -> Data {
        guard isEncrypted(data) else { return data }

        let key = try getOrCreateKey()
        let nonceStart = Self.headerSize
        let ciphertextStart = nonceStart + Self.nonceSize
        let tagStart = data.count - Self.tagSize

        guard tagStart >= ciphertextStart else {
            throw EncryptionError.invalidFormat
        }

        let nonce = try AES.GCM.Nonce(data: data[nonceStart..<ciphertextStart])
        let ciphertext = data[ciphertextStart..<tagStart]
        let tag = data[tagStart...]

        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(sealedBox, using: key)
    }

    func isEncrypted(_ data: Data) -> Bool {
        guard data.count >= Self.overhead else { return false }
        return data[0] == Self.magic[0]
            && data[1] == Self.magic[1]
            && data[2] == Self.magic[2]
            && data[3] == Self.magic[3]
            && data[4] == Self.formatVersion
    }

    // MARK: - File Operations

    func encryptAndWrite(_ data: Data, to url: URL) throws {
        let encrypted = try encrypt(data)
        try encrypted.write(to: url, options: .atomic)
    }

    func readAndDecrypt(from url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        return try decrypt(data)
    }

    func migrateFileIfNeeded(at url: URL) throws {
        let data = try Data(contentsOf: url)
        guard !isEncrypted(data) else { return }
        try encryptAndWrite(data, to: url)
    }

    // MARK: - Errors

    enum EncryptionError: Error, LocalizedError {
        case keychainError(OSStatus)
        case invalidFormat

        var errorDescription: String? {
            switch self {
            case .keychainError(let status):
                return "Keychain error: \(status)"
            case .invalidFormat:
                return "Invalid encrypted data format"
            }
        }
    }
}
