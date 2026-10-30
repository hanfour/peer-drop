import Foundation
import CryptoKit
import PeerDropNotes
import PeerDropSecurity

/// Controls which identity types may join a group.
public enum JoinPolicy: String, Codable, Sendable {
    /// Allows only account-backed members.
    case accountOnly
    /// Allows anonymous members.
    case anonymousAllowed
}

private struct GroupAdminContext {
    let client: GroupClient
    let secrets: GroupSecretsStore
    let identity: GroupIdentity
    let record: GroupStore.PersistedGroup
}

extension GroupStore {
    /// Removes a member and processes any room-key rotation triggered by the kick.
    public func kick(_ id: String, memberId: String) async throws {
        try await withOperationLock { [self] in
            let context = try adminContext(id, ownerOnly: true)
            guard Self.isValidAdminId(memberId) else { throw GroupError.badId }

            do {
                try await context.client.kick(id: id, memberId: context.identity.memberId, target: memberId)
            } catch {
                let groupError = Self.mapError(error)
                lastError = Self.safeErrorDescription(groupError)
                throw groupError
            }

            lastError = nil
            await sync(id)
            await rotateIfNeeded(id)
        }
    }

    /// Closes a group while keeping its locally stored history readable.
    public func close(_ id: String) async throws {
        try await withOperationLock { [self] in
            let context = try adminContext(id, ownerOnly: true)
            do {
                try await context.client.close(id: id, memberId: context.identity.memberId)
            } catch {
                let groupError = Self.mapError(error)
                lastError = Self.safeErrorDescription(groupError)
                throw groupError
            }

            _ = try persistAdminRecord(id) { record in
                record.summary.state = .closed
            }
            lastError = nil
        }
    }

    /// Replaces the group's invite code and returns the new code.
    public func resetInvite(_ id: String) async throws -> String {
        try await withOperationLock { [self] in
            let context = try adminContext(id, ownerOnly: true)
            let inviteCode: String
            do {
                inviteCode = try await context.client.resetInvite(id: id, memberId: context.identity.memberId)
            } catch {
                let groupError = Self.mapError(error)
                lastError = Self.safeErrorDescription(groupError)
                throw groupError
            }

            _ = try persistAdminRecord(id) { record in
                record.inviteCode = inviteCode
            }
            lastError = nil
            return inviteCode
        }
    }

    /// Updates encrypted group metadata and optional join settings as the owner.
    public func updateMeta(
        _ id: String,
        _ meta: GroupMetaPlaintext,
        joinPolicy: JoinPolicy? = nil,
        removeAnonymous: Bool? = nil
    ) async throws {
        try await withOperationLock { [self] in
            let context = try adminContext(id, ownerOnly: true)
            try Self.validateMeta(meta)
            guard context.record.summary.state != .removed else { throw GroupError.notMember }
            guard !context.record.summary.awaitingKey,
                  let roomKey = context.secrets.roomKey(for: id, epoch: context.record.epoch) else {
                throw GroupError.awaitingKey
            }

            let metaCipher: String
            do {
                metaCipher = try GroupCrypto.sealMeta(
                    meta,
                    key: roomKey,
                    groupId: id,
                    epoch: context.record.epoch
                ).base64EncodedString()
            } catch GroupCryptoError.oversized {
                throw GroupError.tooLarge
            } catch {
                throw Self.mapError(error)
            }
            let eventId = newId()
            guard Self.isValidAdminId(eventId) else { throw GroupError.badId }
            let result: (seq: Int, metaVersion: Int)
            do {
                result = try await context.client.putMeta(
                    id: id,
                    memberId: context.identity.memberId,
                    eventId: eventId,
                    metaCipher: metaCipher,
                    joinPolicy: joinPolicy?.rawValue,
                    removeAnonymous: removeAnonymous ?? false
                )
            } catch {
                let groupError = Self.mapError(error)
                lastError = Self.safeErrorDescription(groupError)
                throw groupError
            }

            _ = try persistAdminRecord(id) { record in
                record.meta = meta
                record.summary.name = meta.name
                if let joinPolicy { record.joinPolicy = joinPolicy.rawValue }
                record.metaVersion = result.metaVersion
            }
            lastError = nil
        }
    }

    /// Reports a locally stored message event, optionally attaching its decrypted text.
    public func report(_ id: String, seq: Int, reason: ReportReason, includeText: Bool) async throws {
        let context = try adminContext(id, ownerOnly: false)
        guard seq > 0 else { throw GroupError.badId }
        guard let event = GroupEventLog(
            url: groupDirectory(id).appendingPathComponent("events.log"),
            encryptor: context.secrets.encryptor
        ).load().events.first(where: { $0.seq == seq }) else {
            throw GroupError.notFound
        }
        guard event.type == "msg" else { throw GroupError.unsupported }

        let excerpt = includeText ? decryptedText(for: event, groupId: id, secrets: context.secrets) : nil
        do {
            _ = try await context.client.report(
                id: id,
                memberId: context.identity.memberId,
                seq: seq,
                reason: reason,
                excerpt: excerpt
            )
            lastError = nil
        } catch {
            let groupError = Self.mapError(error)
            lastError = Self.safeErrorDescription(groupError)
            throw groupError
        }
    }

    private func adminContext(_ id: String, ownerOnly: Bool) throws -> GroupAdminContext {
        guard Self.isValidAdminId(id) else { throw GroupError.badId }
        guard let record = try readRecord(id) else { throw GroupError.notFound }
        if ownerOnly && !record.isOwner { throw GroupError.notOwner }
        guard !isMock, let client, let secrets else { throw GroupError.network("mock") }
        guard Self.isValidAdminId(record.myMemberId),
              let identity = secrets.identity(for: id), identity.memberId == record.myMemberId,
              identity.kind.rawValue == record.identityKind.rawValue else {
            throw GroupError.notMember
        }
        if ownerOnly && !identity.isOwner { throw GroupError.notOwner }
        if ownerOnly && record.summary.state == .removed { throw GroupError.notMember }
        return GroupAdminContext(client: client, secrets: secrets, identity: identity, record: record)
    }

    private func persistAdminRecord(
        _ id: String,
        update: (inout PersistedGroup) -> Void
    ) throws -> PersistedGroup {
        guard var record = try readRecord(id) else { throw GroupError.notFound }
        update(&record)
        do {
            try writeRecord(record)
        } catch {
            let groupError = Self.mapError(error)
            lastError = Self.safeErrorDescription(groupError)
            throw groupError
        }
        apply(record: record, members: states[id]?.members ?? [])
        return record
    }

    private static func validateMeta(_ meta: GroupMetaPlaintext) throws {
        guard !meta.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              meta.name.unicodeScalars.count <= GroupLimits.nameScalars,
              meta.description.map({ $0.unicodeScalars.count <= GroupLimits.descriptionScalars }) ?? true,
              meta.photo.map({ $0.count <= GroupLimits.photoBytes }) ?? true,
              customBackgroundFits(meta.background) else {
            throw GroupError.tooLarge
        }
        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(meta)
        } catch {
            throw GroupError.network("invalid_meta")
        }
        guard encoded.count <= GroupLimits.metaBytes else { throw GroupError.tooLarge }
    }

    private static func customBackgroundFits(_ background: GroupBackground?) -> Bool {
        guard case let .custom(data)? = background else { return true }
        return data.count <= GroupLimits.customBackgroundBytes
    }

    private func decryptedText(for event: WireEvent, groupId: String, secrets: GroupSecretsStore) -> String? {
        guard let encodedCipher = event.payloadCipher,
              let cipher = Data(base64Encoded: encodedCipher),
              let key = secrets.roomKey(for: groupId, epoch: event.epoch),
              let payload = try? GroupCrypto.openMessage(
                cipher,
                key: key,
                groupId: groupId,
                memberId: event.authorMemberId,
                eventId: event.eventId,
                epoch: event.epoch
              ),
              payload.kind == .text,
              let text = payload.text else { return nil }
        return Self.truncatedExcerpt(text)
    }

    private static func truncatedExcerpt(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard scalars.count > 1_000 else { return text }
        return String(String.UnicodeScalarView(scalars.prefix(1_000)))
    }

    private static func isValidAdminId(_ id: String) -> Bool {
        guard id.utf8.count == 26 else { return false }
        return id.range(of: "^[0-9A-HJKMNP-TV-Z]{26}$", options: .regularExpression) != nil
    }
}
