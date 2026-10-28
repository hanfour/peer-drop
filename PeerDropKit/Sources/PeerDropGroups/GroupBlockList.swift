import Foundation
import PeerDropSecurity

/// Stores the locally blocked member ids for each group in encrypted files.
public final class GroupBlockList {
    private static let ioLock = NSLock()
    private static let idPattern = "^[0-9A-HJKMNP-TV-Z]{26}$"

    private let directory: URL
    private let encryptor: ChatDataEncryptor

    /// Creates a block list rooted beside the group's encrypted metadata.
    public init(directory: URL, encryptor: ChatDataEncryptor = .shared) {
        self.directory = directory
        self.encryptor = encryptor
    }

    /// Adds one member id to the encrypted block list for a group.
    public func block(memberId: String, in groupId: String) throws {
        try requireValid(groupId: groupId, memberId: memberId)
        Self.ioLock.lock()
        defer { Self.ioLock.unlock() }

        var members = try readMembers(groupId)
        members.insert(memberId)
        try writeMembers(members, groupId: groupId)
    }

    /// Removes one member id from the encrypted block list for a group.
    public func unblock(memberId: String, in groupId: String) throws {
        try requireValid(groupId: groupId, memberId: memberId)
        Self.ioLock.lock()
        defer { Self.ioLock.unlock() }

        var members = try readMembers(groupId)
        members.remove(memberId)
        try writeMembers(members, groupId: groupId)
    }

    /// Returns whether the member id is blocked in the given group.
    public func isBlocked(memberId: String, in groupId: String) -> Bool {
        guard Self.isValid(groupId), Self.isValid(memberId) else { return false }
        Self.ioLock.lock()
        defer { Self.ioLock.unlock() }
        return (try? readMembers(groupId).contains(memberId)) ?? false
    }

    private func readMembers(_ groupId: String) throws -> Set<String> {
        let url = fileURL(groupId)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try encryptor.readAndDecrypt(from: url)
            return Set(try JSONDecoder().decode([String].self, from: data).filter(Self.isValid))
        } catch {
            throw GroupBlockListError.unreadableFile
        }
    }

    private func writeMembers(_ members: Set<String>, groupId: String) throws {
        let url = fileURL(groupId)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encryptor.encryptAndWrite(JSONEncoder().encode(members.sorted()), to: url)
        } catch {
            throw GroupBlockListError.cannotWrite
        }
    }

    private func fileURL(_ groupId: String) -> URL {
        directory.appendingPathComponent(groupId, isDirectory: true).appendingPathComponent("blocked-members.enc")
    }

    private func requireValid(groupId: String, memberId: String) throws {
        guard Self.isValid(groupId) else { throw GroupBlockListError.invalidGroupId }
        guard Self.isValid(memberId) else { throw GroupBlockListError.invalidMemberId }
    }

    private static func isValid(_ id: String) -> Bool {
        id.count == 26 && id.range(of: idPattern, options: .regularExpression) != nil
    }
}

/// Failures raised while reading or updating encrypted blocked member ids.
public enum GroupBlockListError: Error, Equatable {
    case invalidGroupId
    case invalidMemberId
    case unreadableFile
    case cannotWrite
}
