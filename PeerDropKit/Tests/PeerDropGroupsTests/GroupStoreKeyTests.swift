import Foundation
import CryptoKit
import XCTest
import PeerDropSecurity
@testable import PeerDropGroups

final class GroupStoreKeyTests: XCTestCase {
    private var rootDirectory: URL!
    private var secretsDirectory: URL!
    private var secrets: GroupSecretsStore!
    private var localSigningKey: Curve25519.Signing.PrivateKey!

    override func setUp() {
        GroupTestURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        rootDirectory = root.appendingPathComponent("groups", isDirectory: true)
        secretsDirectory = root.appendingPathComponent("secrets", isDirectory: true)
        secrets = GroupSecretsStore(directory: secretsDirectory, encryptor: GroupTestFixtures.makeEncryptor())
        localSigningKey = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x31, count: 32))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: rootDirectory.deletingLastPathComponent())
    }

    @MainActor
    private func makeStore(
        ids: [String] = [GroupTestFixtures.groupId, GroupTestFixtures.memberId, GroupTestFixtures.eventId],
        directoryKeys: [String: Data] = [:],
        hasLocalAccount: Bool = true
    ) -> GroupStore {
        let signingKey = localSigningKey!
        let local = GroupStore.LocalAccount(
            accountId: GroupTestFixtures.accountId,
            signingPublicKey: signingKey.publicKey.rawRepresentation
        ) { message in
            try signingKey.signature(for: message)
        }
        var keys = directoryKeys
        keys[GroupTestFixtures.accountId] = signingKey.publicKey.rawRepresentation
        return GroupStore(
            client: GroupTestFixtures.makeClient(), directory: StubGroupDirectory(signingKeys: keys),
            secrets: secrets, rootDirectory: rootDirectory,
            localAccount: { hasLocalAccount ? local : nil },
            newId: GroupTestFixtures.makeIdGenerator(ids),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    @MainActor
    private func createGroup(
        _ id: String = GroupTestFixtures.groupId,
        in store: GroupStore,
        name: String = "Hike"
    ) async throws {
        GroupTestURLProtocol.handler = { _ in
            GroupTestFixtures.json("{\"groupId\":\"\(id)\",\"inviteCode\":\"JOIN1234\"}", status: 201)
        }
        _ = try await store.create(name: name, description: nil, category: nil, joinPolicy: "anyone")
        GroupTestURLProtocol.requests.removeAll()
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as! [String: Any]
    }

    private func response<T: Encodable>(_ value: T, status: Int = 200) -> GroupTestURLProtocol.Stub {
        GroupTestURLProtocol.Stub(status: status, body: try! JSONEncoder().encode(value))
    }

    private func accountMember(
        groupId: String = GroupTestFixtures.groupId,
        memberId: String,
        accountId: String,
        signingKey: Curve25519.Signing.PrivateKey,
        roomKey: Curve25519.KeyAgreement.PrivateKey = .init(),
        hasKey: Bool,
        corruptPubKeySignature: Bool = false
    ) -> WireMember {
        let publicKey = roomKey.publicKey.rawRepresentation
        let message = GroupCrypto.memberKeyMessage(
            groupId: groupId, memberId: memberId, accountId: accountId, pubKey: publicKey
        )
        var signature = GroupCrypto.sign(message, with: signingKey)
        if corruptPubKeySignature { signature[signature.startIndex] ^= 1 }
        return WireMember(
            memberId: memberId, kind: "account", accountId: accountId, joinedAt: 1,
            pubKey: publicKey.base64EncodedString(), pubKeySig: signature.base64EncodedString(), hasKey: hasKey
        )
    }

    private func anonymousMember(
        groupId: String = GroupTestFixtures.groupId,
        memberId: String,
        roomKey: Curve25519.KeyAgreement.PrivateKey = .init(),
        hasKey: Bool
    ) -> WireMember {
        WireMember(
            memberId: memberId, kind: "anon", joinedAt: 1,
            pubKey: roomKey.publicKey.rawRepresentation.base64EncodedString(), hasKey: hasKey
        )
    }

    private func view(
        groupId: String = GroupTestFixtures.groupId,
        ownerMemberId: String = GroupTestFixtures.memberId,
        members: [WireMember],
        epoch: UInt32 = 1,
        rotationDue: Bool = false
    ) -> GroupView {
        GroupView(
            groupId: groupId, ownerMemberId: ownerMemberId, members: members,
            joinPolicy: "anyone", state: "open", epoch: epoch, seq: 0, firstSeq: 1,
            metaVersion: 0, rotationDue: rotationDue
        )
    }

    @MainActor
    private func ownerMember(groupId: String = GroupTestFixtures.groupId) throws -> WireMember {
        let identity = try XCTUnwrap(secrets.identity(for: groupId))
        let roomKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: identity.roomPrivateKey)
        return accountMember(
            groupId: groupId, memberId: identity.memberId, accountId: GroupTestFixtures.accountId,
            signingKey: localSigningKey, roomKey: roomKey, hasKey: true
        )
    }

    @MainActor
    func testInstallKeysVerifiesWrapperSignature() async throws {
        let directorySigning = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x42, count: 32))
        let unknownSigning = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x43, count: 32))
        let validWrapperId = "01ARZ3NDEKTSV4RRFFQ69G5FAY"
        let forgedWrapperId = "01ARZ3NDEKTSV4RRFFQ69G5FAZ"
        let unknownWrapperId = "01ARZ3NDEKTSV4RRFFQ69G5FB0"
        let wrapperRoom = Curve25519.KeyAgreement.PrivateKey()
        let forgedRoom = Curve25519.KeyAgreement.PrivateKey()
        let unknownRoom = Curve25519.KeyAgreement.PrivateKey()
        let store = makeStore(directoryKeys: ["PDRP0042": directorySigning.publicKey.rawRepresentation])
        try await createGroup(in: store)
        let owner = try ownerMember()
        let validWrapper = accountMember(
            memberId: validWrapperId, accountId: "PDRP0042", signingKey: directorySigning,
            roomKey: wrapperRoom, hasKey: true
        )
        let forgedWrapper = accountMember(
            memberId: forgedWrapperId, accountId: "PDRP0042", signingKey: directorySigning,
            roomKey: forgedRoom, hasKey: true
        )
        let unknownWrapper = accountMember(
            memberId: unknownWrapperId, accountId: "PDRP0043", signingKey: unknownSigning,
            roomKey: unknownRoom, hasKey: true
        )
        let validKey = SymmetricKey(size: .bits256)
        let forgedKey = SymmetricKey(size: .bits256)
        let unknownKey = SymmetricKey(size: .bits256)
        let futureKey = SymmetricKey(size: .bits256)
        let ownerPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Data(base64Encoded: owner.pubKey)!)

        func wrap(_ key: SymmetricKey, epoch: UInt32, wrapper: WireMember, signingKey: Curve25519.Signing.PrivateKey) throws -> WireWrap {
            let wrapped = try GroupCrypto.wrap(
                roomKey: key, groupId: GroupTestFixtures.groupId, epoch: epoch,
                recipientMemberId: owner.memberId, recipientPublicKey: ownerPublicKey
            )
            let message = GroupCrypto.wrapMessage(
                groupId: GroupTestFixtures.groupId, epoch: epoch, target: owner.memberId,
                wrapper: wrapper.memberId, wrapped: wrapped
            )
            return WireWrap(
                epoch: epoch, wrapped: wrapped.base64EncodedString(), wrappedBy: wrapper.memberId,
                sig: GroupCrypto.sign(message, with: signingKey).base64EncodedString()
            )
        }

        let valid = try wrap(validKey, epoch: 2, wrapper: validWrapper, signingKey: directorySigning)
        var forged = try wrap(forgedKey, epoch: 3, wrapper: forgedWrapper, signingKey: directorySigning)
        var forgedSignature = Data(base64Encoded: forged.sig)!
        forgedSignature[forgedSignature.startIndex] ^= 1
        forged = WireWrap(epoch: forged.epoch, wrapped: forged.wrapped, wrappedBy: forged.wrappedBy, sig: forgedSignature.base64EncodedString())
        let unknown = try wrap(unknownKey, epoch: 4, wrapper: unknownWrapper, signingKey: unknownSigning)
        let future = try wrap(futureKey, epoch: 5, wrapper: validWrapper, signingKey: directorySigning)
        let wraps = [valid, forged, unknown, future]
        GroupTestURLProtocol.handler = { request in
            if request.url?.path == "/v3/groups/\(GroupTestFixtures.groupId)/keys" {
                return self.response(WrapsResponse(wraps: wraps))
            }
            if request.url?.path == "/v3/groups/\(GroupTestFixtures.groupId)" {
                return self.response(self.view(members: [owner, validWrapper, forgedWrapper, unknownWrapper], epoch: 4))
            }
            return GroupTestFixtures.json("{}", status: 500)
        }
        let otherGroupId = "01ARZ3NDEKTSV4RRFFQ69G5FB1"
        let otherKey = SymmetricKey(size: .bits256)
        try secrets.saveRoomKey(otherKey, for: otherGroupId, epoch: 2)

        await store.installKeys(for: GroupTestFixtures.groupId)
        await store.installKeys(for: GroupTestFixtures.groupId)

        let installed = try XCTUnwrap(secrets.roomKey(for: GroupTestFixtures.groupId, epoch: 2))
        XCTAssertEqual(installed.withUnsafeBytes { Data($0) }, validKey.withUnsafeBytes { Data($0) })
        XCTAssertNil(secrets.roomKey(for: GroupTestFixtures.groupId, epoch: 3))
        XCTAssertNil(secrets.roomKey(for: GroupTestFixtures.groupId, epoch: 4))
        XCTAssertNil(secrets.roomKey(for: GroupTestFixtures.groupId, epoch: 5))
        XCTAssertEqual(
            secrets.roomKey(for: otherGroupId, epoch: 2)?.withUnsafeBytes { Data($0) },
            otherKey.withUnsafeBytes { Data($0) }
        )
        XCTAssertEqual(GroupTestURLProtocol.requests.filter { $0.url?.path.hasSuffix("/keys") == true }.count, 2)
    }

    @MainActor
    func testRelayWrapsOnlyForMembersWithoutKeyAndVerifiesPubKeySig() async throws {
        let goodSigning = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x51, count: 32))
        let badSigning = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x52, count: 32))
        let goodRoom = Curve25519.KeyAgreement.PrivateKey()
        let badRoom = Curve25519.KeyAgreement.PrivateKey()
        let anonRoom = Curve25519.KeyAgreement.PrivateKey()
        let hasKeyId = "01ARZ3NDEKTSV4RRFFQ69G5FB2"
        let goodId = "01ARZ3NDEKTSV4RRFFQ69G5FB3"
        let badId = "01ARZ3NDEKTSV4RRFFQ69G5FB4"
        let anonId = "01ARZ3NDEKTSV4RRFFQ69G5FB5"
        let store = makeStore(directoryKeys: [
            "PDRP0051": goodSigning.publicKey.rawRepresentation,
            "PDRP0052": badSigning.publicKey.rawRepresentation
        ])
        try await createGroup(in: store)
        let owner = try ownerMember()
        let alreadyKeyed = accountMember(
            memberId: hasKeyId, accountId: "PDRP0051", signingKey: goodSigning,
            roomKey: Curve25519.KeyAgreement.PrivateKey(), hasKey: true
        )
        let validMissing = accountMember(
            memberId: goodId, accountId: "PDRP0051", signingKey: goodSigning,
            roomKey: goodRoom, hasKey: false
        )
        let invalidMissing = accountMember(
            memberId: badId, accountId: "PDRP0052", signingKey: badSigning,
            roomKey: badRoom, hasKey: false, corruptPubKeySignature: true
        )
        let anon = anonymousMember(memberId: anonId, roomKey: anonRoom, hasKey: false)
        var viewRequestCount = 0
        var putBodies: [[String: Any]] = []
        GroupTestURLProtocol.handler = { request in
            if request.url?.path == "/v3/groups/\(GroupTestFixtures.groupId)" {
                viewRequestCount += 1
                let members = [owner, alreadyKeyed, validMissing, invalidMissing, anon].map { member in
                    if (member.memberId == goodId || member.memberId == anonId) && putBodies.count > 0 {
                        return WireMember(
                            memberId: member.memberId, kind: member.kind, accountId: member.accountId,
                            joinedAt: member.joinedAt, pubKey: member.pubKey, pubKeySig: member.pubKeySig, hasKey: true
                        )
                    }
                    return member
                }
                return self.response(self.view(members: members))
            }
            if request.url?.path == "/v3/groups/\(GroupTestFixtures.groupId)/keys", request.httpMethod == "PUT" {
                putBodies.append(try! self.body(request))
                return GroupTestFixtures.json("{\"written\":[\"\(goodId)\",\"\(anonId)\"],\"skipped\":[\"\(badId)\"]}")
            }
            return GroupTestFixtures.json("{}", status: 500)
        }

        await store.relayKeys(for: GroupTestFixtures.groupId)
        await store.relayKeys(for: GroupTestFixtures.groupId)

        XCTAssertEqual(viewRequestCount, 2)
        XCTAssertEqual(putBodies.count, 1)
        let submitted = try XCTUnwrap(putBodies.first?["wraps"] as? [[String: String]])
        XCTAssertEqual(Set(submitted.compactMap { $0["memberId"] }), Set([goodId, anonId]))
        let currentKey = try XCTUnwrap(secrets.roomKey(for: GroupTestFixtures.groupId, epoch: 1))
        for item in submitted {
            let memberId = try XCTUnwrap(item["memberId"])
            let wrapped = try XCTUnwrap(Data(base64Encoded: item["wrapped"]!))
            let signature = try XCTUnwrap(Data(base64Encoded: item["sig"]!))
            let message = GroupCrypto.wrapMessage(
                groupId: GroupTestFixtures.groupId, epoch: 1, target: memberId,
                wrapper: owner.memberId, wrapped: wrapped
            )
            XCTAssertTrue(GroupCrypto.verify(
                signature: signature, message: message, signingPublicKey: localSigningKey.publicKey.rawRepresentation
            ))
            let recipientPrivateKey = memberId == goodId ? goodRoom : anonRoom
            let unwrapped = try GroupCrypto.unwrap(
                wrapped, groupId: GroupTestFixtures.groupId, epoch: 1, memberId: memberId,
                privateKey: recipientPrivateKey
            )
            XCTAssertEqual(unwrapped.withUnsafeBytes { Data($0) }, currentKey.withUnsafeBytes { Data($0) })
        }
    }

    @MainActor
    func testRelayOnlyByAccountMember() async throws {
        let groupId = "01ARZ3NDEKTSV4RRFFQ69G5FB6"
        let store = makeStore(ids: [groupId, GroupTestFixtures.memberId], hasLocalAccount: false)
        GroupTestURLProtocol.handler = { request in
            if request.url?.path == "/v3/groups/join" {
                return GroupTestFixtures.json(
                    "{\"groupId\":\"\(groupId)\",\"memberId\":\"\(GroupTestFixtures.memberId)\",\"epoch\":1,\"state\":\"open\",\"ownerMemberId\":null}"
                )
            }
            if request.url?.path == "/v3/groups/\(groupId)/keys" {
                return GroupTestFixtures.json("{\"wraps\":[]}")
            }
            return GroupTestFixtures.json("{}", status: 500)
        }
        _ = try await store.join(code: "JOIN1234", as: .anon, nickname: "Guest")
        GroupTestURLProtocol.requests.removeAll()

        await store.relayKeys(for: groupId)

        XCTAssertTrue(GroupTestURLProtocol.requests.isEmpty)
    }

    @MainActor
    func testRotateWrapsEveryCurrentMemberAndReencryptsMeta() async throws {
        let peerSigning = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x61, count: 32))
        let peerRoom = Curve25519.KeyAgreement.PrivateKey()
        let anonRoom = Curve25519.KeyAgreement.PrivateKey()
        let peerId = "01ARZ3NDEKTSV4RRFFQ69G5FB7"
        let anonId = "01ARZ3NDEKTSV4RRFFQ69G5FB8"
        let store = makeStore(
            ids: [GroupTestFixtures.groupId, GroupTestFixtures.memberId, GroupTestFixtures.eventId],
            directoryKeys: ["PDRP0061": peerSigning.publicKey.rawRepresentation]
        )
        try await createGroup(in: store, name: "Original name")
        let owner = try ownerMember()
        let peer = accountMember(
            memberId: peerId, accountId: "PDRP0061", signingKey: peerSigning,
            roomKey: peerRoom, hasKey: true
        )
        let anon = anonymousMember(memberId: anonId, roomKey: anonRoom, hasKey: true)
        let oldKey = try XCTUnwrap(secrets.roomKey(for: GroupTestFixtures.groupId, epoch: 1))
        let oldEventId = "01ARZ3NDEKTSV4RRFFQ69G5FB9"
        let oldCipher = try GroupCrypto.sealMessage(
            GroupMessagePayload(kind: .text, text: "old epoch"), key: oldKey,
            groupId: GroupTestFixtures.groupId, memberId: owner.memberId, eventId: oldEventId, epoch: 1
        )
        var rotateBody: [String: Any]?
        var viewCount = 0
        GroupTestURLProtocol.handler = { request in
            if request.url?.path == "/v3/groups/\(GroupTestFixtures.groupId)" {
                viewCount += 1
                return self.response(self.view(
                    members: [owner, peer, anon], epoch: viewCount == 1 ? 1 : 2,
                    rotationDue: viewCount == 1
                ))
            }
            if request.url?.path == "/v3/groups/\(GroupTestFixtures.groupId)/rotate" {
                rotateBody = try! self.body(request)
                return GroupTestFixtures.json("{\"seq\":4,\"epoch\":2}")
            }
            return GroupTestFixtures.json("{}", status: 500)
        }

        await store.rotateIfNeeded(GroupTestFixtures.groupId)

        let request = try XCTUnwrap(GroupTestURLProtocol.requests.first { $0.url?.path.hasSuffix("/rotate") == true })
        let sent = try XCTUnwrap(rotateBody)
        XCTAssertEqual(sent["epoch"] as? Int, 2)
        let wraps = try XCTUnwrap(sent["wraps"] as? [[String: String]])
        XCTAssertEqual(wraps.count, 3)
        XCTAssertEqual(Set(wraps.compactMap { $0["memberId"] }), Set([owner.memberId, peerId, anonId]))
        let ownerWrap = try XCTUnwrap(wraps.first { $0["memberId"] == owner.memberId })
        let newKey = try GroupCrypto.unwrap(
            Data(base64Encoded: ownerWrap["wrapped"]!)!, groupId: GroupTestFixtures.groupId,
            epoch: 2, memberId: owner.memberId,
            privateKey: Curve25519.KeyAgreement.PrivateKey(rawRepresentation: secrets.identity(for: GroupTestFixtures.groupId)!.roomPrivateKey)
        )
        for item in wraps {
            let memberId = try XCTUnwrap(item["memberId"])
            let wrapped = try XCTUnwrap(Data(base64Encoded: item["wrapped"]!))
            let signature = try XCTUnwrap(Data(base64Encoded: item["sig"]!))
            let message = GroupCrypto.wrapMessage(
                groupId: GroupTestFixtures.groupId, epoch: 2, target: memberId,
                wrapper: owner.memberId, wrapped: wrapped
            )
            XCTAssertTrue(GroupCrypto.verify(
                signature: signature, message: message, signingPublicKey: localSigningKey.publicKey.rawRepresentation
            ))
            let recipientPrivateKey: Curve25519.KeyAgreement.PrivateKey
            if memberId == owner.memberId {
                recipientPrivateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: secrets.identity(for: GroupTestFixtures.groupId)!.roomPrivateKey)
            } else if memberId == peerId {
                recipientPrivateKey = peerRoom
            } else {
                recipientPrivateKey = anonRoom
            }
            let openedKey = try GroupCrypto.unwrap(
                wrapped, groupId: GroupTestFixtures.groupId, epoch: 2, memberId: memberId,
                privateKey: recipientPrivateKey
            )
            XCTAssertEqual(openedKey.withUnsafeBytes { Data($0) }, newKey.withUnsafeBytes { Data($0) })
        }
        let metaCipher = try XCTUnwrap(Data(base64Encoded: sent["metaCipher"] as! String))
        XCTAssertEqual(try GroupCrypto.openMeta(metaCipher, key: newKey, groupId: GroupTestFixtures.groupId, epoch: 2).name, "Original name")
        XCTAssertEqual(
            try GroupCrypto.openMessage(
                oldCipher, key: try XCTUnwrap(secrets.roomKey(for: GroupTestFixtures.groupId, epoch: 1)),
                groupId: GroupTestFixtures.groupId, memberId: owner.memberId, eventId: oldEventId, epoch: 1
            ).text,
            "old epoch"
        )
        XCTAssertEqual(
            secrets.roomKey(for: GroupTestFixtures.groupId, epoch: 2)?.withUnsafeBytes { Data($0) },
            newKey.withUnsafeBytes { Data($0) }
        )
        XCTAssertEqual(request.httpMethod, "POST")
    }

    @MainActor
    func testRotateRetriesOnMembersChanged() async throws {
        let peerSigning = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x71, count: 32))
        let peerId = "01ARZ3NDEKTSV4RRFFQ69G5FBA"
        let peerRoom = Curve25519.KeyAgreement.PrivateKey()
        let store = makeStore(
            ids: [GroupTestFixtures.groupId, GroupTestFixtures.memberId, GroupTestFixtures.eventId, "01ARZ3NDEKTSV4RRFFQ69G5FBB"],
            directoryKeys: ["PDRP0071": peerSigning.publicKey.rawRepresentation]
        )
        try await createGroup(in: store)
        let owner = try ownerMember()
        let peer = accountMember(
            memberId: peerId, accountId: "PDRP0071", signingKey: peerSigning,
            roomKey: peerRoom, hasKey: true
        )
        var views = 0
        var rotations: [[String: Any]] = []
        GroupTestURLProtocol.handler = { request in
            if request.url?.path == "/v3/groups/\(GroupTestFixtures.groupId)" {
                let epoch: UInt32 = views < 2 ? 1 : 2
                views += 1
                return self.response(self.view(
                    members: views == 1 ? [owner] : [owner, peer], epoch: epoch, rotationDue: views < 3
                ))
            }
            if request.url?.path == "/v3/groups/\(GroupTestFixtures.groupId)/rotate" {
                rotations.append(try! self.body(request))
                return rotations.count == 1
                    ? GroupTestFixtures.json("{\"error\":\"members_changed\"}", status: 409)
                    : GroupTestFixtures.json("{\"seq\":5,\"epoch\":2}")
            }
            return GroupTestFixtures.json("{}", status: 500)
        }

        await store.rotateIfNeeded(GroupTestFixtures.groupId)

        XCTAssertEqual(views, 3)
        XCTAssertEqual(rotations.count, 2)
        XCTAssertEqual((rotations.last?["wraps"] as? [[String: String]])?.count, 2)
        XCTAssertNotNil(secrets.roomKey(for: GroupTestFixtures.groupId, epoch: 2))
    }

    @MainActor
    func testRotateOnlyForOwner() async throws {
        let peerId = "01ARZ3NDEKTSV4RRFFQ69G5FBC"
        let store = makeStore()
        try await createGroup(in: store)
        let owner = try ownerMember()
        let peerSigning = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x72, count: 32))
        let peer = accountMember(
            memberId: peerId, accountId: "PDRP0072", signingKey: peerSigning, hasKey: true
        )
        GroupTestURLProtocol.handler = { request in
            if request.url?.path == "/v3/groups/\(GroupTestFixtures.groupId)" {
                return self.response(self.view(
                    ownerMemberId: peerId, members: [owner, peer], rotationDue: true
                ))
            }
            return GroupTestFixtures.json("{}", status: 500)
        }

        await store.rotateIfNeeded(GroupTestFixtures.groupId)

        XCTAssertFalse(GroupTestURLProtocol.requests.contains { $0.url?.path.hasSuffix("/rotate") == true })
        XCTAssertEqual(store.groups.first?.state, .open)
    }

    @MainActor
    func testNoRotationWhenNotDue() async throws {
        let store = makeStore()
        try await createGroup(in: store)
        let owner = try ownerMember()
        GroupTestURLProtocol.handler = { request in
            if request.url?.path == "/v3/groups/\(GroupTestFixtures.groupId)" {
                return self.response(self.view(members: [owner], rotationDue: false))
            }
            return GroupTestFixtures.json("{}", status: 500)
        }

        await store.rotateIfNeeded(GroupTestFixtures.groupId)

        XCTAssertEqual(GroupTestURLProtocol.requests.count, 1)
        XCTAssertFalse(GroupTestURLProtocol.requests.contains { $0.url?.path.hasSuffix("/rotate") == true })
    }

    @MainActor
    func testPushKeyRequestTriggersRelay() async throws {
        let targetId = "01ARZ3NDEKTSV4RRFFQ69G5FBD"
        let targetRoom = Curve25519.KeyAgreement.PrivateKey()
        let store = makeStore()
        try await createGroup(in: store)
        let owner = try ownerMember()
        let target = anonymousMember(memberId: targetId, roomKey: targetRoom, hasKey: true)
        var putCount = 0
        GroupTestURLProtocol.handler = { request in
            if request.url?.path == "/v3/groups/\(GroupTestFixtures.groupId)" {
                return self.response(self.view(members: [owner, target]))
            }
            if request.url?.path == "/v3/groups/\(GroupTestFixtures.groupId)/keys", request.httpMethod == "PUT" {
                putCount += 1
                return GroupTestFixtures.json("{\"written\":[\"\(targetId)\"],\"skipped\":[]}")
            }
            return GroupTestFixtures.json("{}", status: 500)
        }

        await store.handlePush(kind: "groupKeyRequest", groupId: GroupTestFixtures.groupId)

        XCTAssertEqual(putCount, 1)
        let sent = try XCTUnwrap(GroupTestURLProtocol.requests.first { $0.httpMethod == "PUT" })
        XCTAssertEqual(try body(sent)["epoch"] as? Int, 1)
        XCTAssertEqual((try body(sent)["wraps"] as? [[String: String]])?.first?["memberId"], targetId)
    }

    @MainActor
    func testPushForUnknownGroupDoesNotThrow() async throws {
        let unknownId = "01ARZ3NDEKTSV4RRFFQ69G5FBE"
        let store = makeStore()
        GroupTestURLProtocol.handler = { request in
            if request.url?.path == "/v3/groups" { return GroupTestFixtures.json("[]") }
            return GroupTestFixtures.json("{}", status: 500)
        }

        await store.handlePush(kind: "groupMessage", groupId: unknownId)

        XCTAssertEqual(GroupTestURLProtocol.requests.map { $0.url?.path }, ["/v3/groups"])
        XCTAssertTrue(store.unknownGroupIds.isEmpty)
    }
}

private struct WrapsResponse: Encodable {
    let wraps: [WireWrap]
}
