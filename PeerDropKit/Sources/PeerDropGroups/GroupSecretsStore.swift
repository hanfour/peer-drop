import Foundation
import CryptoKit
import PeerDropSecurity

/// The local member identity and room private key used by a group.
public struct GroupIdentity: Codable, Equatable {
    /// The authentication type used by this group member.
    public enum Kind: String, Codable, Equatable {
        case account
        case anon
    }

    public let memberId: String
    public let kind: Kind
    public let roomPrivateKey: Data
    public let createdAt: Date
    public let isOwner: Bool

    public init(memberId: String, kind: Kind, roomPrivateKey: Data, createdAt: Date, isOwner: Bool) {
        self.memberId = memberId
        self.kind = kind
        self.roomPrivateKey = roomPrivateKey
        self.createdAt = createdAt
        self.isOwner = isOwner
    }
}

/// Stores each group's local identity and encrypted room keys by epoch.
public final class GroupSecretsStore {
    public let directory: URL
    public let encryptor: ChatDataEncryptor

    public init(directory: URL? = nil, encryptor: ChatDataEncryptor = .shared) {
        self.directory = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Groups", isDirectory: true)
        self.encryptor = encryptor
    }

    /// Returns nil when the identity is absent, unreadable, or has an invalid private-key length.
    public func identity(for groupId: String) -> GroupIdentity? {
        guard let data = try? encryptor.readAndDecrypt(from: identityURL(for: groupId)),
              let identity = try? JSONDecoder().decode(GroupIdentity.self, from: data),
              identity.roomPrivateKey.count == 32 else { return nil }
        return identity
    }

    /// Encrypts and atomically saves the group's local identity.
    public func saveIdentity(_ identity: GroupIdentity, for groupId: String) throws {
        guard identity.roomPrivateKey.count == 32 else { throw GroupSecretsStoreError.invalidKeyLength }
        let url = identityURL(for: groupId)
        try createGroupDirectory(for: groupId)
        try encryptor.encryptAndWrite(JSONEncoder().encode(identity), to: url)
    }

    /// Returns a room key only when its stored value decodes to exactly 32 bytes.
    public func roomKey(for groupId: String, epoch: UInt32) -> SymmetricKey? {
        guard let stored = storedRoomKeys(for: groupId),
              let encoded = stored[String(epoch)],
              let data = Data(base64Encoded: encoded),
              data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    /// Encrypts and atomically saves one room key while retaining other epochs.
    public func saveRoomKey(_ key: SymmetricKey, for groupId: String, epoch: UInt32) throws {
        let keyData = key.withUnsafeBytes { Data($0) }
        guard keyData.count == 32 else { throw GroupSecretsStoreError.invalidKeyLength }

        var stored = storedRoomKeys(for: groupId) ?? [:]
        stored[String(epoch)] = keyData.base64EncodedString()
        let url = keysURL(for: groupId)
        try createGroupDirectory(for: groupId)
        try encryptor.encryptAndWrite(JSONEncoder().encode(stored), to: url)
    }

    /// Returns the saved epochs in ascending order, excluding malformed keys.
    public func epochs(for groupId: String) -> [UInt32] {
        guard let stored = storedRoomKeys(for: groupId) else { return [] }
        return stored.compactMap { epochString, encoded -> UInt32? in
            guard let epoch = UInt32(epochString),
                  let data = Data(base64Encoded: encoded),
                  data.count == 32 else { return nil }
            return epoch
        }.sorted()
    }

    /// Returns the greatest epoch with a valid stored room key.
    public func latestEpoch(for groupId: String) -> UInt32? {
        epochs(for: groupId).last
    }

    /// Removes all locally stored secrets for a group; absent groups are ignored.
    public func remove(group groupId: String) throws {
        let url = groupDirectory(for: groupId)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Lists the group directories currently present in this store.
    public func allGroupIds() -> [String] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            return url.lastPathComponent
        }.sorted()
    }

    private func groupDirectory(for groupId: String) -> URL {
        directory.appendingPathComponent(groupId, isDirectory: true)
    }

    private func identityURL(for groupId: String) -> URL {
        groupDirectory(for: groupId).appendingPathComponent("identity.enc")
    }

    private func keysURL(for groupId: String) -> URL {
        groupDirectory(for: groupId).appendingPathComponent("keys.enc")
    }

    private func createGroupDirectory(for groupId: String) throws {
        try FileManager.default.createDirectory(
            at: groupDirectory(for: groupId),
            withIntermediateDirectories: true
        )
    }

    private func storedRoomKeys(for groupId: String) -> [String: String]? {
        guard let data = try? encryptor.readAndDecrypt(from: keysURL(for: groupId)) else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }
}

private enum GroupSecretsStoreError: Error {
    case invalidKeyLength
}
