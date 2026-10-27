import Foundation
import Combine
import CryptoKit
import PeerDropAccount
import PeerDropSecurity

/// Coordinates local group identities, membership requests, and encrypted list metadata.
@MainActor
public final class GroupStore: ObservableObject {
    /// The local account id and signing operations used for account members.
    public struct LocalAccount {
        public let accountId: String
        public let signingPublicKey: Data
        public let sign: (Data) throws -> Data

        public init(accountId: String, signingPublicKey: Data, sign: @escaping (Data) throws -> Data) {
            self.accountId = accountId
            self.signingPublicKey = signingPublicKey
            self.sign = sign
        }
    }

    @Published public private(set) var groups: [GroupSummary] = []
    @Published public private(set) var states: [String: GroupState] = [:]
    @Published public private(set) var lastError: String?
    @Published public private(set) var unknownGroupIds: Set<String> = []

    private let client: GroupClient?
    private let directory: GroupDirectory?
    private let secrets: GroupSecretsStore?
    private let rootDirectory: URL?
    private let localAccount: () -> LocalAccount?
    private let newId: () -> String
    private let now: () -> Date
    private let isMock: Bool
    private var operationGate: Task<Void, Never>?

    private struct PendingCreate: Codable {
        let groupId: String
        let memberId: String
        let accountId: String
        let signingPublicKey: Data
        let meta: GroupMetaPlaintext
        let metaCipher: String
        let joinPolicy: String
    }

    private struct PendingJoin: Codable {
        let targetGroupId: String?
        let storageGroupId: String
        let inviteCode: String
        let memberId: String
        let kind: IdentityKind
        let nickname: String?
        let accountId: String?
        let signingPublicKey: Data?
        let createdIdentity: Bool
    }

    private struct PersistedGroup: Codable {
        var groupId: String
        var summary: GroupSummary
        var inviteCode: String?
        var meta: GroupMetaPlaintext?
        var myMemberId: String
        var identityKind: IdentityKind
        var joinPolicy: String
        var isOwner: Bool
        var epoch: UInt32
        var rotationDue: Bool
        var identityEventId: String?
        var pendingIdentityNickname: String?
    }

    /// Creates a live store and restores its encrypted local group list.
    public init(
        client: GroupClient,
        directory: GroupDirectory,
        secrets: GroupSecretsStore,
        rootDirectory: URL,
        localAccount: @escaping () -> LocalAccount?,
        newId: @escaping () -> String,
        now: @escaping () -> Date = Date.init
    ) {
        self.client = client
        self.directory = directory
        self.secrets = secrets
        self.rootDirectory = rootDirectory
        self.localAccount = localAccount
        self.newId = newId
        self.now = now
        self.isMock = false
        load()
    }

    /// Creates a network-free store for previews.
    public init(mock groups: [GroupSummary], states: [String: GroupState]) {
        self.client = nil
        self.directory = nil
        self.secrets = nil
        self.rootDirectory = nil
        self.localAccount = { nil }
        self.newId = { "" }
        self.now = Date.init
        self.isMock = true
        self.groups = groups
        self.states = states
    }

    /// Reloads group summaries from the encrypted per-group metadata files.
    public func load() {
        guard !isMock, let rootDirectory else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: rootDirectory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else {
            groups = []
            states = [:]
            return
        }

        var loadedGroups: [GroupSummary] = []
        var loadedStates: [String: GroupState] = [:]
        for entry in entries where (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let groupId = entry.lastPathComponent
            guard Self.isValidGroupId(groupId),
                  let record = try? readRecord(groupId),
                  record.groupId == groupId else { continue }
            loadedGroups.append(record.summary)
            loadedStates[groupId] = makeState(from: record)
        }
        groups = loadedGroups.sorted { $0.groupId < $1.groupId }
        states = loadedStates
    }

    /// Finds account groups without automatically adding unknown server memberships locally.
    public func syncList() async {
        guard !isMock, let client else { return }
        do {
            let rows = try await client.list()
            let known = Set(groups.map(\.groupId))
            unknownGroupIds = Set(rows.map(\.groupId).filter { !known.contains($0) })
            lastError = nil
        } catch {
            let groupError = Self.mapError(error)
            lastError = Self.safeErrorDescription(groupError)
        }
    }

    /// Creates a group and persists its identity and first room key before making the request.
    public func create(name: String, description: String?, category: String?, joinPolicy: String) async throws -> String {
        try await withOperationLock { [self] in
            try await performCreate(name: name, description: description, category: category, joinPolicy: joinPolicy)
        }
    }

    /// Joins a group from its key-free invite URL.
    public func join(link: URL, as kind: IdentityKind, nickname: String?) async throws -> String {
        guard let invite = GroupInviteLink.parse(link) else { throw GroupError.badId }
        return try await withOperationLock { [self] in
            try await performJoin(groupId: invite.groupId, code: invite.code, kind: kind, nickname: nickname)
        }
    }

    /// Joins a group by invite code when its id is not known yet.
    public func join(code: String, as kind: IdentityKind, nickname: String?) async throws -> String {
        guard kind == .anon else { throw GroupError.unsupported }
        guard !code.isEmpty else { throw GroupError.badCode }
        return try await withOperationLock { [self] in
            try await performJoin(groupId: nil, code: code, kind: kind, nickname: nickname)
        }
    }

    /// Leaves a group on the server, then deletes its local metadata and secrets.
    public func leave(_ id: String) async throws {
        guard Self.isValidGroupId(id) else { throw GroupError.badId }
        try await withOperationLock { [self] in
            guard !isMock, let client, let secrets else { throw GroupError.network("mock") }
            guard let identity = secrets.identity(for: id) else {
                try removeLocalData(id)
                return
            }
            do {
                try await client.leave(id: id, memberId: identity.memberId)
            } catch {
                let groupError = Self.mapError(error)
                guard groupError == .notMember || groupError == .notFound else {
                    lastError = Self.safeErrorDescription(groupError)
                    throw groupError
                }
            }
            try removeLocalData(id)
            lastError = nil
        }
    }

    /// Returns this group's invite URL when an invite code is available locally.
    public func inviteLink(for id: String) -> URL? {
        guard !isMock, Self.isValidGroupId(id), let record = try? readRecord(id),
              let code = record.inviteCode else { return nil }
        return GroupInviteLink.make(groupId: id, code: code)
    }

    /// Removes one group's local files and all saved secrets without contacting the server.
    public func remove(localGroup id: String) {
        guard Self.isValidGroupId(id) else {
            lastError = Self.safeErrorDescription(.badId)
            return
        }
        do {
            try removeLocalData(id)
            lastError = nil
        } catch {
            lastError = Self.safeErrorDescription(.network("local_storage"))
        }
    }

    private func performCreate(name: String, description: String?, category: String?, joinPolicy: String) async throws -> String {
        guard !isMock, let client, let secrets else { throw GroupError.network("mock") }
        guard let account = localAccount() else { throw GroupError.accountRequired }
        guard name.unicodeScalars.count <= GroupLimits.nameScalars,
              (description?.unicodeScalars.count ?? 0) <= GroupLimits.descriptionScalars else { throw GroupError.tooLarge }

        let pending: PendingCreate
        do {
            if let saved = try readPending(PendingCreate.self, url: pendingCreateURL) {
                if saved.accountId == account.accountId && saved.signingPublicKey == account.signingPublicKey &&
                    saved.meta.name == name && saved.meta.description == description && saved.meta.category == category &&
                    saved.joinPolicy == joinPolicy {
                    pending = saved
                } else {
                    // Changing parameters can orphan a created group if its create response was lost.
                    try removeSecretsUnlessUnreadable(saved.groupId)
                    try clearPending(at: pendingCreateURL)
                    pending = try makePendingCreate(name: name, description: description, category: category, joinPolicy: joinPolicy, account: account)
                }
            } else {
                pending = try makePendingCreate(name: name, description: description, category: category, joinPolicy: joinPolicy, account: account)
            }
        } catch let error as GroupError {
            lastError = Self.safeErrorDescription(error)
            throw error
        } catch {
            lastError = Self.safeErrorDescription(.network("local_storage"))
            throw GroupError.network("local_storage")
        }

        guard let identity = secrets.identity(for: pending.groupId),
              let roomKey = secrets.roomKey(for: pending.groupId, epoch: 1) else {
            throw GroupError.network("local_identity_missing")
        }
        let roomPrivateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: identity.roomPrivateKey)
        let publicKey = roomPrivateKey.publicKey.rawRepresentation
        let memberMessage = GroupCrypto.memberKeyMessage(
            groupId: pending.groupId, memberId: pending.memberId, accountId: pending.accountId, pubKey: publicKey
        )
        let publicKeySignature = try account.sign(memberMessage)
        guard GroupCrypto.verify(signature: publicKeySignature, message: memberMessage, signingPublicKey: pending.signingPublicKey) else {
            throw GroupError.badSignature
        }
        let wrapped = try GroupCrypto.wrap(
            roomKey: roomKey, groupId: pending.groupId, epoch: 1, recipientMemberId: pending.memberId,
            recipientPublicKey: roomPrivateKey.publicKey
        )
        let wrapMessage = GroupCrypto.wrapMessage(
            groupId: pending.groupId, epoch: 1, target: pending.memberId, wrapper: pending.memberId, wrapped: wrapped
        )
        let wrapSignature = try account.sign(wrapMessage)
        guard GroupCrypto.verify(signature: wrapSignature, message: wrapMessage, signingPublicKey: pending.signingPublicKey) else {
            throw GroupError.badSignature
        }

        let response: (groupId: String, inviteCode: String)
        do {
            response = try await client.create(
                groupId: pending.groupId, memberId: pending.memberId,
                pubKey: publicKey.base64EncodedString(), pubKeySig: publicKeySignature.base64EncodedString(),
                ownerWrap: (wrapped: wrapped.base64EncodedString(), sig: wrapSignature.base64EncodedString()),
                metaCipher: pending.metaCipher, joinPolicy: pending.joinPolicy
            )
        } catch {
            let groupError = Self.mapError(error)
            if Self.isExplicitRejection(groupError) {
                try? removeSecretsUnlessUnreadable(pending.groupId)
                try? clearPending(at: pendingCreateURL)
            }
            lastError = Self.safeErrorDescription(groupError)
            throw groupError
        }
        guard response.groupId == pending.groupId else { throw GroupError.network("group_id_mismatch") }

        let summary = GroupSummary(
            groupId: pending.groupId, name: pending.meta.name, memberCount: 1,
            state: .open, awaitingKey: false
        )
        let record = PersistedGroup(
            groupId: pending.groupId, summary: summary, inviteCode: response.inviteCode, meta: pending.meta,
            myMemberId: pending.memberId, identityKind: .account, joinPolicy: pending.joinPolicy,
            isOwner: true, epoch: 1, rotationDue: false, identityEventId: nil, pendingIdentityNickname: nil
        )
        do {
            try writeRecord(record)
            try clearPending(at: pendingCreateURL)
        } catch {
            lastError = Self.safeErrorDescription(.network("local_storage"))
            throw GroupError.network("local_storage")
        }
        apply(record: record, members: [GroupMember(
            memberId: pending.memberId, kind: .account, accountId: pending.accountId,
            hasKey: true, isOwner: true, pubKeyVerified: true
        )])
        lastError = nil
        return pending.groupId
    }

    private func performJoin(groupId: String?, code: String, kind: IdentityKind, nickname: String?) async throws -> String {
        guard !isMock, let client, let secrets else { throw GroupError.network("mock") }
        guard kind == .anon || localAccount() != nil else { throw GroupError.accountRequired }
        guard (nickname?.unicodeScalars.count ?? 0) <= GroupLimits.nicknameScalars else { throw GroupError.tooLarge }
        if let groupId, !Self.isValidGroupId(groupId) { throw GroupError.badId }

        var joined = false
        var pending: PendingJoin?
        do {
            pending = try prepareJoin(groupId: groupId, code: code, kind: kind, nickname: nickname)
            guard let pending else { throw GroupError.network("local_identity_missing") }
            guard let identity = secrets.identity(for: pending.storageGroupId) else { throw GroupError.network("local_identity_missing") }
            let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: identity.roomPrivateKey)
            let publicKey = privateKey.publicKey.rawRepresentation
            let account = localAccount()
            let publicKeySignature: String?
            if kind == .account {
                guard let account else { throw GroupError.accountRequired }
                guard let groupId else { throw GroupError.unsupported }
                let message = GroupCrypto.memberKeyMessage(
                    groupId: groupId, memberId: identity.memberId,
                    accountId: account.accountId, pubKey: publicKey
                )
                let signature = try account.sign(message)
                guard GroupCrypto.verify(signature: signature, message: message, signingPublicKey: account.signingPublicKey) else {
                    throw GroupError.badSignature
                }
                publicKeySignature = signature.base64EncodedString()
            } else {
                publicKeySignature = nil
            }

            let result: JoinResult
            if let groupId {
                result = try await client.join(
                    id: groupId, memberId: identity.memberId, pubKey: publicKey.base64EncodedString(),
                    pubKeySig: publicKeySignature, as: kind.rawValue, inviteCode: code
                )
            } else {
                result = try await client.joinByCode(
                    memberId: identity.memberId, pubKey: publicKey.base64EncodedString(),
                    pubKeySig: publicKeySignature, as: kind.rawValue, inviteCode: code
                )
            }
            joined = true
            guard Self.isValidGroupId(result.groupId), result.memberId == identity.memberId else { throw GroupError.badId }

            let actualIdentity = try moveIdentity(identity, from: pending.storageGroupId, to: result.groupId)
            let owner = result.ownerMemberId == identity.memberId
            let existing = try existingRecord(result.groupId)
            let summary = GroupSummary(
                groupId: result.groupId, name: existing?.summary.name,
                memberCount: existing?.summary.memberCount ?? 1, unread: existing?.summary.unread ?? 0,
                lastActivity: existing?.summary.lastActivity, state: Self.groupState(result.state),
                awaitingKey: secrets.roomKey(for: result.groupId, epoch: result.epoch) == nil
            )
            let record = PersistedGroup(
                groupId: result.groupId, summary: summary, inviteCode: code, meta: existing?.meta,
                myMemberId: identity.memberId, identityKind: kind, joinPolicy: existing?.joinPolicy ?? "", isOwner: owner,
                epoch: result.epoch, rotationDue: existing?.rotationDue ?? false,
                identityEventId: existing?.identityEventId,
                pendingIdentityNickname: kind == .anon ? (nickname ?? existing?.pendingIdentityNickname) : nil
            )
            try writeRecord(record)
            try clearPending(at: pendingJoinURL)
            apply(record: record, members: [GroupMember(
                memberId: identity.memberId, kind: kind, accountId: account?.accountId,
                hasKey: !summary.awaitingKey, isOwner: owner, pubKeyVerified: kind == .account
            )])

            do {
                if let roomKey = try await loadCurrentRoomKey(
                    groupId: result.groupId, identity: actualIdentity, epoch: result.epoch
                ) {
                    try secrets.saveRoomKey(roomKey, for: result.groupId, epoch: result.epoch)
                    if kind == .anon {
                        try await postIdentity(
                            result.groupId, identity: actualIdentity,
                            nickname: record.pendingIdentityNickname, epoch: result.epoch
                        )
                    }
                    var keyedRecord = try existingRecord(result.groupId) ?? record
                    keyedRecord.summary.awaitingKey = false
                    keyedRecord.pendingIdentityNickname = nil
                    // Cleared only now so a failed write above retries with the same event id.
                    keyedRecord.identityEventId = nil
                    try writeRecord(keyedRecord)
                    apply(record: keyedRecord, members: [GroupMember(
                        memberId: identity.memberId, kind: kind, accountId: account?.accountId,
                        hasKey: true, isOwner: owner, pubKeyVerified: kind == .account
                    )])
                }
            } catch {
                let groupError = Self.mapError(error)
                var retryRecord = (try? existingRecord(result.groupId)) ?? record
                retryRecord.summary.awaitingKey = secrets.roomKey(for: result.groupId, epoch: result.epoch) == nil
                if kind == .anon { retryRecord.pendingIdentityNickname = nickname ?? retryRecord.pendingIdentityNickname }
                try? writeRecord(retryRecord)
                apply(record: retryRecord, members: [GroupMember(
                    memberId: identity.memberId, kind: kind, accountId: account?.accountId,
                    hasKey: secrets.roomKey(for: result.groupId, epoch: result.epoch) != nil,
                    isOwner: owner, pubKeyVerified: kind == .account
                )])
                lastError = Self.safeErrorDescription(groupError)
                return result.groupId
            }
            lastError = nil
            return result.groupId
        } catch {
            let groupError = Self.mapError(error)
            if !joined, let pending, Self.isExplicitRejection(groupError) {
                if pending.createdIdentity { try? removeSecretsUnlessUnreadable(pending.storageGroupId) }
                try? clearPending(at: pendingJoinURL)
            }
            lastError = Self.safeErrorDescription(groupError)
            throw groupError
        }
    }

    private func makePendingCreate(
        name: String,
        description: String?,
        category: String?,
        joinPolicy: String,
        account: LocalAccount
    ) throws -> PendingCreate {
        guard let secrets else { throw GroupError.network("mock") }
        let groupId = newId()
        let memberId = newId()
        guard Self.isValidGroupId(groupId), Self.isValidGroupId(memberId) else { throw GroupError.badId }
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let identity = GroupIdentity(
            memberId: memberId, kind: .account, roomPrivateKey: privateKey.rawRepresentation,
            createdAt: now(), isOwner: true
        )
        let roomKey = SymmetricKey(size: .bits256)
        do {
            try ensureIdentityWritable(groupId)
            try secrets.saveIdentity(identity, for: groupId)
            try secrets.saveRoomKey(roomKey, for: groupId, epoch: 1)
            let meta = GroupMetaPlaintext(name: name, description: description, category: category)
            let metaCipher = try GroupCrypto.sealMeta(meta, key: roomKey, groupId: groupId, epoch: 1).base64EncodedString()
            let pending = PendingCreate(
                groupId: groupId, memberId: memberId, accountId: account.accountId,
                signingPublicKey: account.signingPublicKey, meta: meta, metaCipher: metaCipher, joinPolicy: joinPolicy
            )
            try writePending(pending, to: pendingCreateURL)
            return pending
        } catch let error as GroupError {
            try? removeSecretsUnlessUnreadable(groupId)
            throw error
        } catch {
            try? removeSecretsUnlessUnreadable(groupId)
            throw GroupError.network("local_storage")
        }
    }

    private func prepareJoin(groupId: String?, code: String, kind: IdentityKind, nickname: String?) throws -> PendingJoin {
        guard let secrets else { throw GroupError.network("mock") }
        let account = localAccount()
        if let pending = try readPending(PendingJoin.self, url: pendingJoinURL),
           pending.targetGroupId == groupId, pending.inviteCode == code, pending.kind == kind,
           pending.nickname == nickname, pending.accountId == account?.accountId,
           pending.signingPublicKey == account?.signingPublicKey,
           secrets.identity(for: pending.storageGroupId) != nil {
            return pending
        }

        if let old = try readPending(PendingJoin.self, url: pendingJoinURL) {
            if old.createdIdentity { try removeSecretsUnlessUnreadable(old.storageGroupId) }
            try clearPending(at: pendingJoinURL)
        }

        let storedGroupId: String
        let existingIdentity: GroupIdentity?
        if let groupId {
            storedGroupId = groupId
            existingIdentity = secrets.identity(for: groupId)
        } else {
            storedGroupId = newId()
            guard Self.isValidGroupId(storedGroupId) else { throw GroupError.badId }
            existingIdentity = nil
        }

        let identity: GroupIdentity
        let createdIdentity: Bool
        if let existingIdentity {
            guard existingIdentity.kind == (kind == .anon ? .anon : .account) else { throw GroupError.exists }
            identity = existingIdentity
            createdIdentity = false
        } else {
            let memberId = newId()
            guard Self.isValidGroupId(memberId) else { throw GroupError.badId }
            identity = GroupIdentity(
                memberId: memberId, kind: kind == .anon ? .anon : .account,
                roomPrivateKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation,
                createdAt: now(), isOwner: false
            )
            createdIdentity = true
            do {
                try ensureIdentityWritable(storedGroupId)
                try secrets.saveIdentity(identity, for: storedGroupId)
            } catch {
                throw GroupError.network("local_storage")
            }
        }

        let pending = PendingJoin(
            targetGroupId: groupId, storageGroupId: storedGroupId, inviteCode: code,
            memberId: identity.memberId, kind: kind, nickname: nickname,
            accountId: account?.accountId, signingPublicKey: account?.signingPublicKey,
            createdIdentity: createdIdentity
        )
        do {
            try writePending(pending, to: pendingJoinURL)
        } catch {
            if createdIdentity { try? removeSecretsUnlessUnreadable(storedGroupId) }
            throw GroupError.network("local_storage")
        }
        return pending
    }

    private func moveIdentity(_ identity: GroupIdentity, from source: String, to destination: String) throws -> GroupIdentity {
        guard let secrets else { throw GroupError.network("mock") }
        if source != destination {
            if let existing = secrets.identity(for: destination), existing.memberId != identity.memberId {
                throw GroupError.exists
            }
            try ensureIdentityWritable(destination)
            if secrets.identity(for: destination) == nil { try secrets.saveIdentity(identity, for: destination) }
            try removeSecretsUnlessUnreadable(source)
        }
        return identity
    }

    private func loadCurrentRoomKey(groupId: String, identity: GroupIdentity, epoch: UInt32) async throws -> SymmetricKey? {
        guard let client, let directory else { return nil }
        let wraps = try await client.myKeys(id: groupId, memberId: identity.memberId)
        guard let wireWrap = wraps.first(where: { $0.epoch == epoch }),
              let wrapped = Data(base64Encoded: wireWrap.wrapped),
              let signature = Data(base64Encoded: wireWrap.sig) else { return nil }
        let view = try await client.view(id: groupId, memberId: identity.memberId)
        guard let wrapper = view.members.first(where: { $0.memberId == wireWrap.wrappedBy }),
              wrapper.kind == "account", let accountId = wrapper.accountId,
              let publicKey = Data(base64Encoded: wrapper.pubKey),
              let memberSignature = wrapper.pubKeySig.flatMap({ Data(base64Encoded: $0) }),
              let signingKey = await directory.signingKey(accountId: accountId) else { throw GroupError.badSignature }
        let memberMessage = GroupCrypto.memberKeyMessage(
            groupId: groupId, memberId: wrapper.memberId, accountId: accountId, pubKey: publicKey
        )
        let wrapMessage = GroupCrypto.wrapMessage(
            groupId: groupId, epoch: epoch, target: identity.memberId, wrapper: wrapper.memberId, wrapped: wrapped
        )
        guard GroupCrypto.verify(signature: memberSignature, message: memberMessage, signingPublicKey: signingKey),
              GroupCrypto.verify(signature: signature, message: wrapMessage, signingPublicKey: signingKey) else {
            throw GroupError.badSignature
        }
        return try GroupCrypto.unwrap(
            wrapped, groupId: groupId, epoch: epoch, memberId: identity.memberId,
            privateKey: Curve25519.KeyAgreement.PrivateKey(rawRepresentation: identity.roomPrivateKey)
        )
    }

    private func postIdentity(_ groupId: String, identity: GroupIdentity, nickname: String?, epoch: UInt32) async throws {
        guard identity.kind == .anon, let client, let secrets,
              let roomKey = secrets.roomKey(for: groupId, epoch: epoch) else { return }
        let eventId: String
        if var record = try readRecord(groupId) {
            if let savedId = record.identityEventId {
                eventId = savedId
            } else {
                eventId = newId()
                guard Self.isValidGroupId(eventId) else { throw GroupError.badId }
                record.identityEventId = eventId
                try writeRecord(record)
            }
        } else {
            throw GroupError.network("local_metadata_missing")
        }
        let payload = GroupMessagePayload(kind: .identity, nickname: nickname)
        let cipher = try GroupCrypto.sealMessage(
            payload, key: roomKey, groupId: groupId, memberId: identity.memberId,
            eventId: eventId, epoch: epoch
        )
        _ = try await client.postMessage(
            id: groupId, memberId: identity.memberId, eventId: eventId, epoch: epoch,
            payloadCipher: cipher.base64EncodedString()
        )
    }

    private func makeState(from record: PersistedGroup) -> GroupState {
        let member = GroupMember(
            memberId: record.myMemberId, kind: record.identityKind,
            accountId: nil, hasKey: !record.summary.awaitingKey, isOwner: record.isOwner,
            pubKeyVerified: record.identityKind == .account
        )
        return GroupState(
            groupId: record.groupId, meta: record.meta, members: [member],
            isOwner: record.isOwner, myMemberId: record.myMemberId,
            identityKind: record.identityKind, joinPolicy: record.joinPolicy,
            state: record.summary.state, epoch: record.epoch, rotationDue: record.rotationDue
        )
    }

    private func apply(record: PersistedGroup, members: [GroupMember]) {
        if let index = groups.firstIndex(where: { $0.groupId == record.groupId }) {
            groups[index] = record.summary
        } else {
            groups.append(record.summary)
        }
        groups.sort { $0.groupId < $1.groupId }
        states[record.groupId] = GroupState(
            groupId: record.groupId, meta: record.meta, members: members,
            isOwner: record.isOwner, myMemberId: record.myMemberId,
            identityKind: record.identityKind, joinPolicy: record.joinPolicy,
            state: record.summary.state, epoch: record.epoch, rotationDue: record.rotationDue
        )
    }

    private func existingRecord(_ groupId: String) throws -> PersistedGroup? {
        try readRecord(groupId)
    }

    private func readRecord(_ groupId: String) throws -> PersistedGroup? {
        guard Self.isValidGroupId(groupId) else { throw GroupError.badId }
        return try readEncrypted(PersistedGroup.self, url: metadataURL(groupId))
    }

    private func writeRecord(_ record: PersistedGroup) throws {
        guard Self.isValidGroupId(record.groupId), record.summary.groupId == record.groupId else { throw GroupError.badId }
        if let existing = try readRecord(record.groupId), existing.groupId != record.groupId {
            throw GroupError.network("local_metadata_mismatch")
        }
        try writeEncrypted(record, url: metadataURL(record.groupId))
    }

    private func removeLocalData(_ groupId: String) throws {
        guard Self.isValidGroupId(groupId), secrets != nil else { throw GroupError.badId }
        guard try removeSecretsUnlessUnreadable(groupId) else { throw GroupError.network("local_storage_unreadable") }
        let directory = groupDirectory(groupId)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        groups.removeAll { $0.groupId == groupId }
        states[groupId] = nil
    }

    private func ensureIdentityWritable(_ groupId: String) throws {
        guard let secrets else { throw GroupError.network("mock") }
        let identityURL = secrets.directory.appendingPathComponent(groupId, isDirectory: true).appendingPathComponent("identity.enc")
        if FileManager.default.fileExists(atPath: identityURL.path), secrets.identity(for: groupId) == nil {
            throw GroupError.network("identity_unreadable")
        }
    }

    /// Removes a group's secrets unless they exist but cannot be read; returns false in that case so the
    /// caller can decide whether leaving them behind is acceptable (cleanup) or must be reported (leave).
    @discardableResult
    private func removeSecretsUnlessUnreadable(_ groupId: String) throws -> Bool {
        guard let secrets else { throw GroupError.network("mock") }
        let groupDirectory = secrets.directory.appendingPathComponent(groupId, isDirectory: true)
        let identityURL = groupDirectory.appendingPathComponent("identity.enc")
        let keysURL = groupDirectory.appendingPathComponent("keys.enc")
        if FileManager.default.fileExists(atPath: identityURL.path), secrets.identity(for: groupId) == nil {
            return false
        }
        if FileManager.default.fileExists(atPath: keysURL.path), secrets.epochs(for: groupId).isEmpty {
            return false
        }
        try secrets.remove(group: groupId)
        return true
    }

    private func readEncrypted<T: Decodable>(_ type: T.Type, url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let secrets else { throw GroupError.network("mock") }
        do {
            return try JSONDecoder().decode(type, from: secrets.encryptor.readAndDecrypt(from: url))
        } catch {
            throw GroupError.network("local_storage_unreadable")
        }
    }

    private func writeEncrypted<T: Encodable>(_ value: T, url: URL) throws {
        guard let secrets else { throw GroupError.network("mock") }
        if FileManager.default.fileExists(atPath: url.path) {
            if url == pendingCreateURL {
                _ = try readEncrypted(PendingCreate.self, url: url)
            } else if url == pendingJoinURL {
                _ = try readEncrypted(PendingJoin.self, url: url)
            } else {
                _ = try readEncrypted(PersistedGroup.self, url: url)
            }
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try secrets.encryptor.encryptAndWrite(JSONEncoder().encode(value), to: url)
        } catch let error as GroupError {
            throw error
        } catch {
            throw GroupError.network("local_storage")
        }
    }

    /// Moves an undecryptable pending record aside so create/join are not blocked forever. Trade-off: a
    /// keychain failure looks the same as corruption, so a resend may then start with fresh ids.
    private func readPending<T: Decodable>(_ type: T.Type, url: URL) throws -> T? {
        do {
            return try readEncrypted(type, url: url)
        } catch let error as GroupError where error == .network("local_storage_unreadable") {
            let corruptURL = url.appendingPathExtension("corrupt")
            do {
                if FileManager.default.fileExists(atPath: corruptURL.path) {
                    try FileManager.default.removeItem(at: corruptURL)
                }
                try FileManager.default.moveItem(at: url, to: corruptURL)
                return nil
            } catch {
                throw GroupError.network("local_storage")
            }
        }
    }

    private func writePending<T: Encodable>(_ value: T, to url: URL) throws {
        try writeEncrypted(value, url: url)
    }

    private func clearPending(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private var pendingCreateURL: URL { rootDirectory!.appendingPathComponent("pending-create.enc") }
    private var pendingJoinURL: URL { rootDirectory!.appendingPathComponent("pending-join.enc") }
    private func groupDirectory(_ groupId: String) -> URL { rootDirectory!.appendingPathComponent(groupId, isDirectory: true) }
    private func metadataURL(_ groupId: String) -> URL { groupDirectory(groupId).appendingPathComponent("group.enc") }

    private func withOperationLock<T>(_ body: @MainActor @escaping () async throws -> T) async throws -> T {
        let previous = operationGate
        let work = Task<T, Error> { @MainActor in
            _ = await previous?.value
            return try await body()
        }
        operationGate = Task { @MainActor in _ = try? await work.value }
        return try await work.value
    }

    private static let groupIdPattern = "^[0-9A-HJKMNP-TV-Z]{26}$"

    private static func isValidGroupId(_ id: String) -> Bool {
        id.range(of: groupIdPattern, options: .regularExpression) != nil
    }

    private static func groupState(_ wireState: String) -> GroupSummary.State {
        wireState == "closed" ? .closed : .open
    }

    private static func mapError(_ error: Error) -> GroupError {
        if let groupError = error as? GroupError { return groupError }
        return GroupError.from(error)
    }

    private static func isExplicitRejection(_ error: GroupError) -> Bool {
        switch error {
        case .badCode, .notFound, .closed, .banned, .membersFull, .groupLimit, .exists,
             .tooLarge, .badId, .badSignature, .accountRequired, .notMember:
            return true
        default:
            return false
        }
    }

    private static func safeErrorDescription(_ error: GroupError) -> String {
        switch error {
        case .notMember: return "not_member"
        case .awaitingKey: return "awaiting_key"
        case .staleEpoch: return "stale_epoch"
        case .membersChanged: return "members_changed"
        case .notOwner: return "not_owner"
        case .closed: return "closed"
        case .banned: return "banned"
        case .badCode: return "bad_code"
        case .accountRequired: return "account_required"
        case .bearerRequired: return "bearer_required"
        case .membersFull: return "members_full"
        case .groupLimit: return "group_limit"
        case .exists: return "exists"
        case .tooLarge: return "too_large"
        case .badSignature: return "bad_signature"
        case .notFound: return "not_found"
        case .badId: return "bad_id"
        case .unsupported: return "unsupported"
        case .transient: return "transient"
        case .network: return "network"
        case .server: return "server_error"
        case .cancelled: return "cancelled"
        }
    }
}
