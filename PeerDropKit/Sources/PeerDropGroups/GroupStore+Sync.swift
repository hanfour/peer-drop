import Foundation
import CryptoKit
import PeerDropSecurity

extension GroupStore {
    /// Synchronizes one group's view and events; concurrent calls coalesce into one follow-up run.
    public func sync(_ id: String) async {
        guard !isMock, Self.isValidGroupId(id) else {
            if !isMock { lastError = Self.safeErrorDescription(.badId) }
            return
        }
        if let task = syncTasks[id] {
            syncRerunRequests.insert(id)
            await task.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                self.syncRerunRequests.remove(id)
                await self.performSync(id)
            } while self.syncRerunRequests.remove(id) != nil
            self.syncTasks[id] = nil
        }
        syncTasks[id] = task
        await task.value
    }

    /// Appends socket or backfill events once, then rebuilds the local message state.
    public func ingest(_ events: [WireEvent], into id: String) {
        guard !isMock, Self.isValidGroupId(id), let secrets else {
            if !isMock { lastError = Self.safeErrorDescription(.badId) }
            return
        }
        do {
            guard let record = try readRecord(id) else { return }
            let log = eventLog(id, encryptor: secrets.encryptor)
            for event in events.sorted(by: Self.eventOrder) {
                try log.append(event)
            }
            rebuildFromLog(id, record: record, events: log.load().events)
        } catch {
            lastError = Self.safeErrorDescription(.network("local_storage"))
        }
    }

    /// Encrypts and posts a text message, retrying timeouts with the same event id.
    public func send(_ id: String, text: String) async throws {
        try await withOperationLock { [self] in
            try await performSend(id, text: text)
        }
    }

    private func performSend(_ id: String, text: String) async throws {
        guard !isMock, Self.isValidGroupId(id), let client, let secrets else {
            throw isMock ? GroupError.network("mock") : GroupError.badId
        }
        guard text.unicodeScalars.count <= GroupLimits.messageScalars,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GroupError.tooLarge
        }
        let payload = GroupMessagePayload(kind: .text, text: text)
        let encodedPayload: Data
        do {
            encodedPayload = try JSONEncoder().encode(payload)
        } catch {
            throw GroupError.network("invalid_payload")
        }
        guard encodedPayload.count + 12 + 16 <= 8 * 1024 else { throw GroupError.tooLarge }

        guard var record = try readRecord(id) else { throw GroupError.notFound }
        guard record.summary.state != .removed else { throw GroupError.notMember }
        guard !record.summary.awaitingKey else { throw GroupError.awaitingKey }
        let epoch = record.epoch
        guard let roomKey = secrets.roomKey(for: id, epoch: epoch) else { throw GroupError.awaitingKey }
        let identity = secrets.identity(for: id)
        guard let identity, identity.memberId == record.myMemberId else { throw GroupError.notMember }

        let eventId = newId()
        guard Self.isValidGroupId(eventId) else { throw GroupError.badId }
        let cipher: String
        do {
            cipher = try GroupCrypto.sealMessage(
                payload, key: roomKey, groupId: id, memberId: identity.memberId,
                eventId: eventId, epoch: epoch
            ).base64EncodedString()
        } catch GroupCryptoError.oversized {
            throw GroupError.tooLarge
        }

        var submittedEpoch = epoch
        var submittedCipher = cipher
        let seq: Int
        do {
            seq = try await postWithTimeoutRetry(
                client: client, groupId: id, identity: identity, eventId: eventId,
                epoch: epoch, payloadCipher: cipher
            )
        } catch let error as GroupError where error == .staleEpoch {
            await sync(id)
            guard let refreshed = try readRecord(id), refreshed.summary.state != .removed else {
                throw GroupError.notMember
            }
            guard refreshed.epoch != epoch else { throw GroupError.staleEpoch }
            record = refreshed
            guard !record.summary.awaitingKey,
                  let refreshedKey = secrets.roomKey(for: id, epoch: record.epoch) else {
                throw GroupError.awaitingKey
            }
            let refreshedCipher: String
            do {
                refreshedCipher = try GroupCrypto.sealMessage(
                    payload, key: refreshedKey, groupId: id, memberId: identity.memberId,
                    eventId: eventId, epoch: record.epoch
                ).base64EncodedString()
            } catch GroupCryptoError.oversized {
                throw GroupError.tooLarge
            }
            submittedEpoch = record.epoch
            submittedCipher = refreshedCipher
            do {
                seq = try await postWithTimeoutRetry(
                    client: client, groupId: id, identity: identity, eventId: eventId,
                    epoch: record.epoch, payloadCipher: refreshedCipher
                )
            } catch {
                let groupError = Self.mapError(error)
                if groupError == .notMember { handleSyncError(groupError, groupId: id) }
                lastError = Self.safeErrorDescription(groupError)
                throw groupError
            }
        } catch {
            let groupError = Self.mapError(error)
            if groupError == .notMember { handleSyncError(groupError, groupId: id) }
            lastError = Self.safeErrorDescription(groupError)
            throw groupError
        }

        let localEvent = WireEvent(
            seq: seq, eventId: eventId, type: "msg", authorMemberId: identity.memberId,
            epoch: submittedEpoch, payloadCipher: submittedCipher, createdAt: Int(now().timeIntervalSince1970 * 1_000)
        )
        lastError = nil
        ingest([localEvent], into: id)
    }

    /// Marks all events currently stored for a group as read.
    public func markRead(_ id: String) {
        guard !isMock, Self.isValidGroupId(id), let secrets else {
            if !isMock { lastError = Self.safeErrorDescription(.badId) }
            return
        }
        do {
            guard var record = try readRecord(id) else { return }
            record.lastReadSeq = eventLog(id, encryptor: secrets.encryptor).lastSeq
            record.summary.unread = 0
            try writeRecord(record)
            apply(record: record, members: states[id]?.members ?? [])
            lastError = nil
        } catch {
            lastError = Self.safeErrorDescription(.network("local_storage"))
        }
    }

    /// Blocks one member locally and hides their messages in this group.
    public func block(memberId: String, in id: String) {
        guard !isMock, Self.isValidGroupId(id), Self.isValidGroupId(memberId), let blockList else {
            if !isMock { lastError = Self.safeErrorDescription(.badId) }
            return
        }
        do {
            try blockList.block(memberId: memberId, in: id)
            rebuildFromStoredLog(id)
            lastError = nil
        } catch {
            lastError = Self.safeErrorDescription(.network("local_storage"))
        }
    }

    /// Removes one member from the local block list and restores eligible stored messages.
    public func unblock(memberId: String, in id: String) {
        guard !isMock, Self.isValidGroupId(id), Self.isValidGroupId(memberId), let blockList else {
            if !isMock { lastError = Self.safeErrorDescription(.badId) }
            return
        }
        do {
            try blockList.unblock(memberId: memberId, in: id)
            rebuildFromStoredLog(id)
            lastError = nil
        } catch {
            lastError = Self.safeErrorDescription(.network("local_storage"))
        }
    }

    /// Returns whether one member is blocked in a group on this device.
    public func isBlocked(memberId: String, in id: String) -> Bool {
        guard !isMock, Self.isValidGroupId(id), let blockList else { return false }
        return blockList.isBlocked(memberId: memberId, in: id)
    }

    private func performSync(_ id: String) async {
        guard let client, let secrets else { return }
        let record: PersistedGroup
        do {
            guard let stored = try readRecord(id) else { return }
            guard stored.summary.state != .removed else { return }
            record = stored
        } catch {
            lastError = Self.safeErrorDescription(Self.mapError(error))
            return
        }

        let view: GroupView
        do {
            view = try await client.view(id: id, memberId: record.myMemberId)
        } catch {
            handleSyncError(error, groupId: id)
            return
        }
        guard view.groupId == id else {
            lastError = Self.safeErrorDescription(.network("group_id_mismatch"))
            return
        }

        var updated = record
        let members = await makeMembers(
            view.members, groupId: id, ownerMemberId: view.ownerMemberId, existing: states[id]?.members ?? []
        )
        updated.epoch = view.epoch
        updated.rotationDue = view.rotationDue
        updated.joinPolicy = view.joinPolicy
        updated.summary.state = Self.groupState(view.state)
        updated.summary.memberCount = members.count
        updated.summary.awaitingKey = !members.contains(where: { $0.memberId == updated.myMemberId && $0.hasKey }) ||
            secrets.roomKey(for: id, epoch: view.epoch) == nil
        updated.membershipSeq = view.seq

        let log = eventLog(id, encryptor: secrets.encryptor)
        if log.lastSeq < view.firstSeq - 1 {
            states[id]?.hasGap = true
        }
        do {
            try writeRecord(updated)
            apply(record: updated, members: members)
            lastError = nil
        } catch {
            lastError = Self.safeErrorDescription(Self.mapError(error))
            return
        }

        var cursor = log.lastSeq
        while true {
            let page: EventsPage
            do {
                page = try await client.events(id: id, memberId: record.myMemberId, since: cursor)
            } catch {
                handleSyncError(error, groupId: id)
                break
            }
            if cursor < page.firstSeq - 1 {
                states[id]?.hasGap = true
            }
            if !page.events.isEmpty {
                ingest(page.events, into: id)
            }
            guard let nextSince = page.nextSince else { break }
            guard nextSince > cursor else { break }
            cursor = nextSince
        }

        do {
            guard var current = try readRecord(id) else { return }
            let allEvents = log.load().events
            let latestMetaVersion = max(view.metaVersion, allEvents.compactMap(\.metaVersion).max() ?? 0)
            if latestMetaVersion > (current.metaVersion ?? 0) {
                current = await refreshMeta(
                    id, record: current, events: allEvents, currentEpoch: view.epoch,
                    requestedVersion: latestMetaVersion, client: client, secrets: secrets
                )
            }
            rebuildFromLog(id, record: current, events: allEvents)
            if current.summary.awaitingKey, let onSyncNeedsKeys {
                await onSyncNeedsKeys(id)
            }
        } catch {
            lastError = Self.safeErrorDescription(Self.mapError(error))
        }
    }

    private func handleSyncError(_ error: Error, groupId: String) {
        let groupError = Self.mapError(error)
        if groupError == .notMember {
            do {
                guard var record = try readRecord(groupId) else { return }
                record.summary.state = .removed
                record.supersededElsewhere = true
                try writeRecord(record)
                apply(record: record, members: states[groupId]?.members ?? [])
                if var state = states[groupId] {
                    state.supersededElsewhere = true
                    states[groupId] = state
                }
            } catch {
                lastError = Self.safeErrorDescription(.network("local_storage"))
                return
            }
        }
        lastError = Self.safeErrorDescription(groupError)
    }

    private func postWithTimeoutRetry(
        client: GroupClient,
        groupId: String,
        identity: GroupIdentity,
        eventId: String,
        epoch: UInt32,
        payloadCipher: String
    ) async throws -> Int {
        do {
            return try await client.postMessage(
                id: groupId, memberId: identity.memberId, eventId: eventId,
                epoch: epoch, payloadCipher: payloadCipher
            )
        } catch let error as GroupError where error == .transient("transport_-1001") {
            return try await client.postMessage(
                id: groupId, memberId: identity.memberId, eventId: eventId,
                epoch: epoch, payloadCipher: payloadCipher
            )
        }
    }

    private func eventLog(_ id: String, encryptor: ChatDataEncryptor) -> GroupEventLog {
        GroupEventLog(url: groupDirectory(id).appendingPathComponent("events.log"), encryptor: encryptor)
    }

    private func rebuildFromStoredLog(_ id: String) {
        guard let secrets, let record = try? readRecord(id) else { return }
        rebuildFromLog(id, record: record, events: eventLog(id, encryptor: secrets.encryptor).load().events)
    }

    private func rebuildFromLog(_ id: String, record: PersistedGroup, events: [WireEvent]) {
        guard let secrets else { return }
        var members = states[id]?.members ?? [GroupMember(
            memberId: record.myMemberId, kind: record.identityKind, hasKey: !record.summary.awaitingKey,
            isOwner: record.isOwner, pubKeyVerified: record.identityKind == .account
        )]
        let membershipStart = record.membershipSeq ?? 0
        for event in events where event.seq > membershipStart {
            switch event.type {
            case "join":
                if !members.contains(where: { $0.memberId == event.authorMemberId }) {
                    members.append(GroupMember(
                        memberId: event.authorMemberId, kind: .anon, hasKey: false,
                        isOwner: false, pubKeyVerified: false
                    ))
                }
            case "leave":
                members.removeAll { $0.memberId == event.authorMemberId }
            case "kick":
                if let target = event.targetMemberId { members.removeAll { $0.memberId == target } }
            default:
                break
            }
        }

        var updated = record
        updated.membershipSeq = max(membershipStart, events.map(\.seq).max() ?? membershipStart)
        updated.summary.memberCount = members.count
        var knownMemberIds = Set(members.map(\.memberId))
        for event in events {
            if event.type == "join" || event.type == "leave" { knownMemberIds.insert(event.authorMemberId) }
            if event.type == "kick", let target = event.targetMemberId { knownMemberIds.insert(target) }
        }

        var messages: [GroupMessage] = []
        var pendingDecryptCount = 0
        for event in events where event.type == "msg" {
            guard knownMemberIds.contains(event.authorMemberId),
                  !isBlocked(memberId: event.authorMemberId, in: id) else { continue }
            guard let cipher = event.payloadCipher, let data = Data(base64Encoded: cipher) else { continue }
            guard let key = secrets.roomKey(for: id, epoch: event.epoch) else {
                pendingDecryptCount += 1
                continue
            }
            do {
                let payload = try GroupCrypto.openMessage(
                    data, key: key, groupId: id, memberId: event.authorMemberId,
                    eventId: event.eventId, epoch: event.epoch
                )
                if payload.kind == .identity {
                    guard members.contains(where: { $0.memberId == event.authorMemberId }),
                          let nickname = payload.nickname else { continue }
                    let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, trimmed.unicodeScalars.count <= GroupLimits.nicknameScalars,
                          let index = members.firstIndex(where: { $0.memberId == event.authorMemberId }) else { continue }
                    members[index].nickname = trimmed
                } else if let text = payload.text {
                    messages.append(GroupMessage(
                        eventId: event.eventId, seq: event.seq, authorMemberId: event.authorMemberId,
                        text: text, createdAt: Date(timeIntervalSince1970: Double(event.createdAt) / 1_000),
                        isMine: event.authorMemberId == record.myMemberId
                    ))
                }
            } catch {
                continue
            }
        }

        updated.summary.unread = messages.filter {
            $0.seq > (updated.lastReadSeq ?? 0) && !$0.isMine && !isBlocked(memberId: $0.authorMemberId, in: id)
        }.count
        if let lastMessage = messages.last { updated.summary.lastActivity = lastMessage.createdAt }
        do {
            try writeRecord(updated)
            apply(record: updated, members: members)
            if var state = states[id] {
                state.messages = messages.sorted(by: Self.messageOrder)
                state.pendingDecryptCount = pendingDecryptCount
                states[id] = state
            }
        } catch {
            lastError = Self.safeErrorDescription(Self.mapError(error))
        }
    }

    private func makeMembers(
        _ wireMembers: [WireMember],
        groupId: String,
        ownerMemberId: String?,
        existing: [GroupMember]
    ) async -> [GroupMember] {
        var members: [GroupMember] = []
        for wire in wireMembers where Self.isValidGroupId(wire.memberId) {
            guard let kind = IdentityKind(rawValue: wire.kind) else { continue }
            let signingKey: Data?
            if kind == .account, let accountId = wire.accountId {
                signingKey = await directory?.signingKey(accountId: accountId)
            } else {
                signingKey = nil
            }
            let verified: Bool
            if kind == .account,
               let accountId = wire.accountId,
               let signingKey,
               let publicKey = Data(base64Encoded: wire.pubKey),
               let signature = wire.pubKeySig.flatMap({ Data(base64Encoded: $0) }) {
                let message = GroupCrypto.memberKeyMessage(
                    groupId: groupId,
                    memberId: wire.memberId, accountId: accountId, pubKey: publicKey
                )
                verified = GroupCrypto.verify(signature: signature, message: message, signingPublicKey: signingKey)
            } else {
                verified = false
            }
            let oldNickname = existing.first(where: { $0.memberId == wire.memberId })?.nickname
            members.append(GroupMember(
                memberId: wire.memberId, kind: kind, accountId: wire.accountId,
                nickname: oldNickname, hasKey: wire.hasKey, isOwner: wire.memberId == ownerMemberId,
                pubKeyVerified: verified
            ))
        }
        return members
    }

    private func refreshMeta(
        _ id: String,
        record: PersistedGroup,
        events: [WireEvent],
        currentEpoch: UInt32,
        requestedVersion: Int,
        client: GroupClient,
        secrets: GroupSecretsStore
    ) async -> PersistedGroup {
        var updated = record
        do {
            let response = try await client.metaCipher(id: id, memberId: record.myMemberId)
            guard response.metaVersion >= requestedVersion,
                  response.metaVersion > (record.metaVersion ?? 0),
                  let cipher = Data(base64Encoded: response.metaCipher) else { return updated }
            let eventEpoch = events
                .filter { $0.type == "meta" && ($0.metaVersion ?? 0) <= response.metaVersion }
                .max(by: { ($0.metaVersion ?? 0) < ($1.metaVersion ?? 0) })?.epoch ?? currentEpoch
            guard let key = secrets.roomKey(for: id, epoch: eventEpoch) else { return updated }
            let meta = try GroupCrypto.openMeta(cipher, key: key, groupId: id, epoch: eventEpoch)
            updated.meta = meta
            updated.metaVersion = response.metaVersion
            updated.summary.name = meta.name
        } catch {
            lastError = Self.safeErrorDescription(Self.mapError(error))
        }
        return updated
    }

    private static func eventOrder(_ lhs: WireEvent, _ rhs: WireEvent) -> Bool {
        if lhs.seq == rhs.seq { return lhs.eventId < rhs.eventId }
        return lhs.seq < rhs.seq
    }

    private static func messageOrder(_ lhs: GroupMessage, _ rhs: GroupMessage) -> Bool {
        if lhs.seq == rhs.seq { return lhs.eventId < rhs.eventId }
        return lhs.seq < rhs.seq
    }
}
