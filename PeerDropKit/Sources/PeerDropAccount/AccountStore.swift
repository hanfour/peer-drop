import Foundation
import os
import PeerDropSecurity

public final class AccountStore {
    private static let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "AccountStore")
    private let storageKey: String
    private let directory: URL
    private let encryptor = ChatDataEncryptor.shared

    public init(storageKey: String = "account", directory: URL? = nil) {
        self.storageKey = storageKey
        self.directory = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Security", isDirectory: true)
    }
    private var url: URL { directory.appendingPathComponent("\(storageKey).enc") }

    public func load() -> Account? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try encryptor.readAndDecrypt(from: url)
            return try JSONDecoder().decode(Account.self, from: data)
        } catch {
            Self.logger.error("account file unreadable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
    public func save(_ account: Account) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encryptor.encryptAndWrite(JSONEncoder().encode(account), to: url)
    }
    public func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
