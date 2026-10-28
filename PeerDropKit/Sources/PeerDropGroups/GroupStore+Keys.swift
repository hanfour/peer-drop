import Foundation
import CryptoKit

private struct VerifiedAccountMemberKey {
    let agreementKey: Curve25519.KeyAgreement.PublicKey
    let signingKey: Data
}

extension GroupStore {
    /// Installs locally addressed room keys after checking the wrapper's account signatures.
    public func installKeys(for id: String) async {
        guard !isMock, isValidKeyId(id), let client else {
            if !isMock { lastError = Self.safeErrorDescription(.badId) }
            return
        }
        do {
            guard let record = try readRecord(id), record.summary.state != .removed else { return }
            let view = try await client.view(id: id, memberId: record.myMemberId)
            try await installKeys(for: id, using: view)
            lastError = nil
        } catch {
            recordKeyLifecycleError(error)
        }
    }

    /// Relays the current room key to members who do not have it yet.
    public func relayKeys(for id: String, force: Bool = false) async {
        guard !isMock, isValidKeyId(id), let client, let secrets,
              let identity = secrets.identity(for: id), identity.kind == .account,
              localAccount() != nil else {
            if !isMock, !isValidKeyId(id) { lastError = Self.safeErrorDescription(.badId) }
            return
        }
        do {
            guard let record = try readRecord(id), record.summary.state != .removed,
                  record.myMemberId == identity.memberId else { return }
            let view = try await client.view(id: id, memberId: identity.memberId)
            try await relayKeys(for: id, force: force, using: view)
            lastError = nil
        } catch {
            recordKeyLifecycleError(error)
        }
    }

    /// Requests delivery of this group's current room key.
    public func requestKey(_ id: String) async throws {
        guard !isMock, isValidKeyId(id), let client, let secrets else {
            throw isMock ? GroupError.network("mock") : GroupError.badId
        }
        do {
            guard let record = try readRecord(id), record.summary.state != .removed,
                  let identity = secrets.identity(for: id), identity.memberId == record.myMemberId else {
                throw GroupError.notFound
            }
            try await client.requestKey(id: id, memberId: identity.memberId)
            lastError = nil
        } catch {
            let groupError = Self.mapError(error)
            recordKeyLifecycleError(groupError)
            throw groupError
        }
    }

    /// Rotates the room key when the server says the owner must do so.
    public func rotateIfNeeded(_ id: String) async {
        guard !isMock, isValidKeyId(id), let client, let secrets else {
            if !isMock { lastError = Self.safeErrorDescription(.badId) }
            return
        }
        do {
            guard let record = try readRecord(id), record.summary.state != .removed,
                  let identity = secrets.identity(for: id), identity.memberId == record.myMemberId else { return }
            let view = try await client.view(id: id, memberId: identity.memberId)
            try await rotateIfNeeded(id, using: view)
            lastError = nil
        } catch {
            recordKeyLifecycleError(error)
        }
    }

    /// Handles a group push without failing when it arrived on a device that has not joined the group.
    public func handlePush(kind: String, groupId: String) async {
        guard !isMock, isValidKeyId(groupId) else { return }
        guard (try? readRecord(groupId)) != nil else {
            await syncList()
            return
        }
        switch kind {
        case "groupMessage":
            await sync(groupId)
        case "groupKeyRequest":
            await relayKeys(for: groupId, force: true)
        default:
            break
        }
    }

    func installKeys(for id: String, using view: GroupView) async throws {
        guard isValidKeyId(id), view.groupId == id,
              let client, let directory, let secrets,
              let record = try readRecord(id), record.summary.state != .removed,
              let identity = secrets.identity(for: id), identity.memberId == record.myMemberId else { return }

        let wraps = try await client.myKeys(id: id, memberId: identity.memberId)
        var storageError: GroupError?
        for wireWrap in wraps where wireWrap.epoch > 0 && wireWrap.epoch <= view.epoch {
            guard isValidKeyId(wireWrap.wrappedBy),
                  let wrapper = view.members.first(where: { $0.memberId == wireWrap.wrappedBy }),
                  wrapper.kind == "account",
                  let verifiedWrapper = await verifiedAccountMemberKey(wrapper, groupId: id, directory: directory),
                  let wrapped = Data(base64Encoded: wireWrap.wrapped), wrapped.count == 92,
                  let signature = Data(base64Encoded: wireWrap.sig) else { continue }

            let wrapMessage = GroupCrypto.wrapMessage(
                groupId: id, epoch: wireWrap.epoch, target: identity.memberId,
                wrapper: wrapper.memberId, wrapped: wrapped
            )
            guard GroupCrypto.verify(
                signature: signature, message: wrapMessage, signingPublicKey: verifiedWrapper.signingKey
            ) else { continue }

            guard let current = try readRecord(id), current.summary.state != .removed,
                  current.myMemberId == identity.memberId else { return }
            guard let roomKey = try? GroupCrypto.unwrap(
                wrapped, groupId: id, epoch: wireWrap.epoch, memberId: identity.memberId,
                privateKey: Curve25519.KeyAgreement.PrivateKey(rawRepresentation: identity.roomPrivateKey)
            ) else { continue }
            do {
                try secrets.saveRoomKey(roomKey, for: id, epoch: wireWrap.epoch)
            } catch {
                if storageError == nil { storageError = .network("local_storage") }
            }
        }

        guard var current = try readRecord(id), current.summary.state != .removed else {
            if let storageError { throw storageError }
            return
        }
        let hasCurrentKey = secrets.roomKey(for: id, epoch: current.epoch) != nil
        current.summary.awaitingKey = !hasCurrentKey
        do {
            try writeRecord(current)
        } catch {
            throw GroupError.network("local_storage")
        }
        applyKeyAvailability(record: current, hasKey: hasCurrentKey)
        if let storageError { throw storageError }
    }

    func relayKeys(for id: String, force: Bool, using view: GroupView) async throws {
        guard view.groupId == id, let client, let directory, let secrets,
              let record = try readRecord(id), record.summary.state != .removed,
              let identity = secrets.identity(for: id), identity.memberId == record.myMemberId,
              identity.kind == .account, let account = localAccount(),
              let roomKey = secrets.roomKey(for: id, epoch: view.epoch),
              let localMember = view.members.first(where: { $0.memberId == identity.memberId }),
              localMember.kind == "account", localMember.accountId == account.accountId,
              await verifiedAccountMemberKey(localMember, groupId: id, directory: directory) != nil else { return }

        var wraps: [WrapIn] = []
        var seen = Set<String>()
        for member in view.members where member.memberId != identity.memberId {
            guard isValidKeyId(member.memberId), seen.insert(member.memberId).inserted,
                  force || !member.hasKey else { continue }

            let recipientPublicKey: Curve25519.KeyAgreement.PublicKey?
            if member.kind == "anon" {
                recipientPublicKey = Data(base64Encoded: member.pubKey)
                    .flatMap { try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: $0) }
            } else if member.kind == "account",
                      let verified = await verifiedAccountMemberKey(member, groupId: id, directory: directory) {
                recipientPublicKey = verified.agreementKey
            } else {
                recipientPublicKey = nil
            }
            guard let recipientPublicKey else { continue }

            do {
                let wrapped = try GroupCrypto.wrap(
                    roomKey: roomKey, groupId: id, epoch: view.epoch,
                    recipientMemberId: member.memberId, recipientPublicKey: recipientPublicKey
                )
                let message = GroupCrypto.wrapMessage(
                    groupId: id, epoch: view.epoch, target: member.memberId,
                    wrapper: identity.memberId, wrapped: wrapped
                )
                let signature = try account.sign(message)
                guard GroupCrypto.verify(
                    signature: signature, message: message, signingPublicKey: account.signingPublicKey
                ) else { continue }
                wraps.append(WrapIn(
                    memberId: member.memberId, wrapped: wrapped.base64EncodedString(),
                    sig: signature.base64EncodedString()
                ))
            } catch {
                continue
            }
        }

        var firstRequestError: GroupError?
        var start = 0
        while start < wraps.count {
            guard let current = try readRecord(id), current.summary.state != .removed,
                  current.myMemberId == identity.memberId else { return }
            let batch = Array(wraps[start..<min(start + 50, wraps.count)])
            do {
                _ = try await client.putKeys(id: id, memberId: identity.memberId, epoch: view.epoch, wraps: batch)
            } catch {
                if firstRequestError == nil { firstRequestError = Self.mapError(error) }
            }
            start += 50
        }
        if let firstRequestError { throw firstRequestError }
    }

    func rotateIfNeeded(_ id: String, using initialView: GroupView) async throws {
        guard initialView.groupId == id, let client, let directory, let secrets,
              let initialRecord = try readRecord(id), initialRecord.summary.state != .removed,
              let identity = secrets.identity(for: id), identity.memberId == initialRecord.myMemberId,
              identity.kind == .account, let account = localAccount() else { return }

        var view = initialView
        var retries = 0
        while true {
            guard view.rotationDue, view.ownerMemberId == identity.memberId,
                  let localMember = view.members.first(where: { $0.memberId == identity.memberId }),
                  localMember.kind == "account", localMember.accountId == account.accountId,
                  await verifiedAccountMemberKey(localMember, groupId: id, directory: directory) != nil else { return }
            guard view.epoch < UInt32.max else { throw GroupError.network("epoch_overflow") }

            do {
                guard let current = try readRecord(id), current.summary.state != .removed,
                      current.myMemberId == identity.memberId else { return }
                let nextEpoch = view.epoch + 1
                let newRoomKey = SymmetricKey(size: .bits256)
                var wraps: [WrapIn] = []
                var seen = Set<String>()
                var wrapFailure = false
                for member in view.members {
                    guard isValidKeyId(member.memberId), seen.insert(member.memberId).inserted else {
                        wrapFailure = true
                        continue
                    }
                    let recipientPublicKey: Curve25519.KeyAgreement.PublicKey?
                    if member.kind == "anon" {
                        recipientPublicKey = Data(base64Encoded: member.pubKey)
                            .flatMap { try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: $0) }
                    } else if member.kind == "account",
                              let verified = await verifiedAccountMemberKey(member, groupId: id, directory: directory) {
                        recipientPublicKey = verified.agreementKey
                    } else {
                        recipientPublicKey = nil
                    }
                    guard let recipientPublicKey else {
                        wrapFailure = true
                        continue
                    }
                    do {
                        let wrapped = try GroupCrypto.wrap(
                            roomKey: newRoomKey, groupId: id, epoch: nextEpoch,
                            recipientMemberId: member.memberId, recipientPublicKey: recipientPublicKey
                        )
                        let message = GroupCrypto.wrapMessage(
                            groupId: id, epoch: nextEpoch, target: member.memberId,
                            wrapper: identity.memberId, wrapped: wrapped
                        )
                        let signature = try account.sign(message)
                        guard GroupCrypto.verify(
                            signature: signature, message: message, signingPublicKey: account.signingPublicKey
                        ) else {
                            wrapFailure = true
                            continue
                        }
                        wraps.append(WrapIn(
                            memberId: member.memberId, wrapped: wrapped.base64EncodedString(),
                            sig: signature.base64EncodedString()
                        ))
                    } catch {
                        wrapFailure = true
                    }
                }
                guard !wrapFailure, !view.members.isEmpty, wraps.count == view.members.count, wraps.count <= 50 else {
                    throw GroupError.badSignature
                }
                guard let rotationRecord = try readRecord(id), rotationRecord.summary.state != .removed,
                      rotationRecord.myMemberId == identity.memberId else { return }
                guard let meta = rotationRecord.meta else { throw GroupError.network("meta_missing") }
                let eventId = newId()
                guard isValidKeyId(eventId) else { throw GroupError.badId }
                let metaCipher = try GroupCrypto.sealMeta(meta, key: newRoomKey, groupId: id, epoch: nextEpoch)
                    .base64EncodedString()
                let result = try await client.rotate(
                    id: id, memberId: identity.memberId, eventId: eventId,
                    epoch: nextEpoch, metaCipher: metaCipher, wraps: wraps
                )
                guard result.epoch == nextEpoch else { throw GroupError.network("epoch_mismatch") }

                let confirmedView = try await client.view(id: id, memberId: identity.memberId)
                guard confirmedView.groupId == id, confirmedView.epoch >= result.epoch else {
                    throw GroupError.staleEpoch
                }
                guard var updated = try readRecord(id), updated.summary.state != .removed,
                      updated.myMemberId == identity.memberId else { return }
                try secrets.saveRoomKey(newRoomKey, for: id, epoch: result.epoch)

                updated.epoch = confirmedView.epoch
                updated.rotationDue = confirmedView.rotationDue
                updated.summary.awaitingKey = secrets.roomKey(for: id, epoch: confirmedView.epoch) == nil
                updated.meta = meta
                updated.summary.name = meta.name
                do {
                    try writeRecord(updated)
                } catch {
                    throw GroupError.network("local_storage")
                }
                applyKeyAvailability(
                    record: updated,
                    hasKey: secrets.roomKey(for: id, epoch: confirmedView.epoch) != nil
                )
                return
            } catch {
                let groupError = Self.mapError(error)
                guard (groupError == .membersChanged || groupError == .staleEpoch), retries < 3 else {
                    throw groupError
                }
                retries += 1
                view = try await client.view(id: id, memberId: identity.memberId)
            }
        }
    }

    private func verifiedAccountMemberKey(
        _ member: WireMember,
        groupId: String,
        directory: GroupDirectory
    ) async -> VerifiedAccountMemberKey? {
        guard member.kind == "account", isValidKeyId(member.memberId),
              let accountId = member.accountId,
              let publicKeyData = Data(base64Encoded: member.pubKey), publicKeyData.count == 32,
              let signature = member.pubKeySig.flatMap({ Data(base64Encoded: $0) }),
              let signingKey = await directory.signingKey(accountId: accountId) else { return nil }
        let message = GroupCrypto.memberKeyMessage(
            groupId: groupId, memberId: member.memberId, accountId: accountId, pubKey: publicKeyData
        )
        guard GroupCrypto.verify(signature: signature, message: message, signingPublicKey: signingKey),
              let agreementKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKeyData) else {
            return nil
        }
        return VerifiedAccountMemberKey(agreementKey: agreementKey, signingKey: signingKey)
    }

    private func applyKeyAvailability(record: PersistedGroup, hasKey: Bool) {
        var members = states[record.groupId]?.members ?? []
        if let index = members.firstIndex(where: { $0.memberId == record.myMemberId }) {
            let member = members[index]
            members[index] = GroupMember(
                memberId: member.memberId, kind: member.kind, accountId: member.accountId,
                nickname: member.nickname, hasKey: hasKey, isOwner: member.isOwner,
                pubKeyVerified: member.pubKeyVerified
            )
        }
        apply(record: record, members: members)
    }

    private func recordKeyLifecycleError(_ error: Error) {
        let groupError = Self.mapError(error)
        if groupError != .cancelled {
            lastError = Self.safeErrorDescription(groupError)
        }
    }

    private func isValidKeyId(_ id: String) -> Bool {
        id.utf8.count == 26 && Self.isValidGroupId(id)
    }
}
