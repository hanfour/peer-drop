import Foundation
import CryptoKit
import XCTest
import PeerDropSecurity
@testable import PeerDropGroups

final class GroupStoreLifecycleTests: XCTestCase {
    private var rootDirectory: URL!
    private var secretsDirectory: URL!
    private var encryptor: ChatDataEncryptor!
    private var secrets: GroupSecretsStore!

    override func setUp() {
        GroupTestURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        rootDirectory = root.appendingPathComponent("groups", isDirectory: true)
        secretsDirectory = root.appendingPathComponent("secrets", isDirectory: true)
        encryptor = GroupTestFixtures.makeEncryptor()
        secrets = GroupSecretsStore(directory: secretsDirectory, encryptor: encryptor)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: rootDirectory.deletingLastPathComponent())
    }

    @MainActor
    private func store(
        ids: [String] = [GroupTestFixtures.groupId, GroupTestFixtures.memberId, GroupTestFixtures.eventId],
        localAccount: GroupStore.LocalAccount? = nil,
        directory: GroupDirectory = StubGroupDirectory(signingKeys: [:])
    ) -> GroupStore {
        let account = localAccount ?? makeLocalAccount()
        return GroupStore(
            client: GroupTestFixtures.makeClient(), directory: directory, secrets: secrets,
            rootDirectory: rootDirectory, localAccount: { account },
            newId: GroupTestFixtures.makeIdGenerator(ids), now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    private func makeLocalAccount() -> GroupStore.LocalAccount {
        let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x31, count: 32))
        return GroupStore.LocalAccount(accountId: GroupTestFixtures.accountId, signingPublicKey: key.publicKey.rawRepresentation) { message in
            GroupCrypto.sign(message, with: key)
        }
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as! [String: Any]
    }

    @MainActor
    func testCreateWritesIdentityBeforeFirstRequest() async throws {
        var identityWasSaved = false
        GroupTestURLProtocol.handler = { request in
            identityWasSaved = self.secrets.identity(for: GroupTestFixtures.groupId) != nil
            return GroupTestFixtures.json("{\"groupId\":\"\(GroupTestFixtures.groupId)\",\"inviteCode\":\"JOIN1234\"}", status: 201)
        }

        _ = try await store().create(name: "Hike", description: nil, category: nil, joinPolicy: "accountOnly")

        XCTAssertTrue(identityWasSaved)
    }

    @MainActor
    func testCreateSignaturesVerifyAgainstVectorsStyleChecks() async throws {
        let local = makeLocalAccount()
        GroupTestURLProtocol.handler = { _ in
            GroupTestFixtures.json("{\"groupId\":\"\(GroupTestFixtures.groupId)\",\"inviteCode\":\"JOIN1234\"}", status: 201)
        }

        _ = try await store(localAccount: local).create(name: "Hike", description: "Saturday", category: "outdoors", joinPolicy: "accountOnly")

        let request = try XCTUnwrap(GroupTestURLProtocol.requests.first)
        let body = try body(request)
        let memberId = try XCTUnwrap(body["memberId"] as? String)
        let pubKey = try XCTUnwrap(Data(base64Encoded: body["pubKey"] as! String))
        let pubKeySig = try XCTUnwrap(Data(base64Encoded: body["pubKeySig"] as! String))
        let ownerWrap = try XCTUnwrap(body["ownerWrap"] as? [String: String])
        let wrapped = try XCTUnwrap(Data(base64Encoded: ownerWrap["wrapped"]!))
        let wrapSig = try XCTUnwrap(Data(base64Encoded: ownerWrap["sig"]!))
        let identity = try XCTUnwrap(secrets.identity(for: GroupTestFixtures.groupId))
        let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x31, count: 32))
        let memberMessage = GroupCrypto.memberKeyMessage(
            groupId: GroupTestFixtures.groupId, memberId: memberId, accountId: GroupTestFixtures.accountId, pubKey: pubKey
        )
        let wrapMessage = GroupCrypto.wrapMessage(
            groupId: GroupTestFixtures.groupId, epoch: 1, target: memberId, wrapper: memberId, wrapped: wrapped
        )

        XCTAssertTrue(GroupCrypto.verify(signature: pubKeySig, message: memberMessage, signingPublicKey: signingKey.publicKey.rawRepresentation))
        XCTAssertTrue(GroupCrypto.verify(signature: wrapSig, message: wrapMessage, signingPublicKey: signingKey.publicKey.rawRepresentation))
        let roomKey = try GroupCrypto.unwrap(
            wrapped, groupId: GroupTestFixtures.groupId, epoch: 1, memberId: memberId,
            privateKey: Curve25519.KeyAgreement.PrivateKey(rawRepresentation: identity.roomPrivateKey)
        )
        XCTAssertEqual(roomKey.withUnsafeBytes { Data($0) }, secrets.roomKey(for: GroupTestFixtures.groupId, epoch: 1)?.withUnsafeBytes { Data($0) })
    }

    @MainActor
    func testCreateResendIsIdempotent() async throws {
        var calls = 0
        GroupTestURLProtocol.handler = { _ in
            calls += 1
            if calls == 1 { return .init(status: 0, body: Data(), error: URLError(.timedOut)) }
            return GroupTestFixtures.json("{\"groupId\":\"\(GroupTestFixtures.groupId)\",\"inviteCode\":\"JOIN1234\"}", status: 200)
        }
        let groupStore = store()

        do {
            _ = try await groupStore.create(name: "Hike", description: nil, category: nil, joinPolicy: "accountOnly")
            XCTFail("expected the first create request to time out")
        } catch {
            XCTAssertEqual(error as? GroupError, .transient("transport_-1001"))
        }
        let first = try body(GroupTestURLProtocol.requests[0])
        _ = try await groupStore.create(name: "Hike", description: nil, category: nil, joinPolicy: "accountOnly")
        let second = try body(GroupTestURLProtocol.requests[1])

        XCTAssertEqual(first["groupId"] as? String, second["groupId"] as? String)
        XCTAssertEqual(first["memberId"] as? String, second["memberId"] as? String)
        XCTAssertEqual(secrets.allGroupIds(), [GroupTestFixtures.groupId])
    }

    @MainActor
    func testJoinAnonymousSendsIdentityMessageAfterJoin() async throws {
        let ownerMemberId = "01ARZ3NDEKTSV4RRFFQ69G5FAY"
        let ownerAccountId = "PDRP0002"
        let ownerSigning = Curve25519.Signing.PrivateKey()
        let ownerRoom = Curve25519.KeyAgreement.PrivateKey()
        let roomKey = SymmetricKey(size: .bits256)
        var wrappedKey: Data?
        var wrapSignature: Data?
        var joiningMemberId: String?
        var joiningPublicKey: Data?
        var identityEventBody: [String: Any]?
        GroupTestURLProtocol.handler = { request in
            switch request.url?.path {
            case "/v3/groups/\(GroupTestFixtures.groupId)/join":
                let joinBody = try! self.body(request)
                let memberId = joinBody["memberId"] as! String
                let publicKey = Data(base64Encoded: joinBody["pubKey"] as! String)!
                joiningMemberId = memberId
                joiningPublicKey = publicKey
                let recipient = try! Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
                let wrapped = try! GroupCrypto.wrap(
                    roomKey: roomKey, groupId: GroupTestFixtures.groupId, epoch: 1,
                    recipientMemberId: memberId, recipientPublicKey: recipient
                )
                wrappedKey = wrapped
                wrapSignature = GroupCrypto.sign(
                    GroupCrypto.wrapMessage(groupId: GroupTestFixtures.groupId, epoch: 1, target: memberId, wrapper: ownerMemberId, wrapped: wrapped),
                    with: ownerSigning
                )
                return GroupTestFixtures.json("{\"groupId\":\"\(GroupTestFixtures.groupId)\",\"memberId\":\"\(memberId)\",\"epoch\":1,\"state\":\"open\",\"ownerMemberId\":\"\(ownerMemberId)\"}", status: 201)
            case "/v3/groups/\(GroupTestFixtures.groupId)/keys":
                let key = wrappedKey!.base64EncodedString()
                let signature = wrapSignature!.base64EncodedString()
                return GroupTestFixtures.json("{\"wraps\":[{\"epoch\":1,\"wrapped\":\"\(key)\",\"wrappedBy\":\"\(ownerMemberId)\",\"sig\":\"\(signature)\"}]}")
            case "/v3/groups/\(GroupTestFixtures.groupId)":
                let ownerPubKey = ownerRoom.publicKey.rawRepresentation
                let ownerMemberSignature = GroupCrypto.sign(
                    GroupCrypto.memberKeyMessage(groupId: GroupTestFixtures.groupId, memberId: ownerMemberId, accountId: ownerAccountId, pubKey: ownerPubKey),
                    with: ownerSigning
                )
                let memberId = joiningMemberId!
                let memberPubKey = joiningPublicKey!.base64EncodedString()
                let owner = "{\"memberId\":\"\(ownerMemberId)\",\"kind\":\"account\",\"accountId\":\"\(ownerAccountId)\",\"joinedAt\":1,\"pubKey\":\"\(ownerPubKey.base64EncodedString())\",\"pubKeySig\":\"\(ownerMemberSignature.base64EncodedString())\",\"hasKey\":true}"
                let joining = "{\"memberId\":\"\(memberId)\",\"kind\":\"anon\",\"joinedAt\":1,\"pubKey\":\"\(memberPubKey)\",\"hasKey\":true}"
                return GroupTestFixtures.json("{\"groupId\":\"\(GroupTestFixtures.groupId)\",\"ownerMemberId\":\"\(ownerMemberId)\",\"members\":[\(owner),\(joining)],\"joinPolicy\":\"anyone\",\"state\":\"open\",\"epoch\":1,\"seq\":1,\"firstSeq\":1,\"metaVersion\":1,\"rotationDue\":false}")
            case "/v3/groups/\(GroupTestFixtures.groupId)/events":
                identityEventBody = try! self.body(request)
                return GroupTestFixtures.json("{\"seq\":2}", status: 201)
            default:
                return .init(status: 404, body: Data("{\"error\":\"not_found\"}".utf8))
            }
        }
        let directory = StubGroupDirectory(signingKeys: [ownerAccountId: ownerSigning.publicKey.rawRepresentation])
        let groupStore = GroupStore(
            client: GroupTestFixtures.makeClient(), directory: directory, secrets: secrets,
            rootDirectory: rootDirectory, localAccount: { nil },
            newId: GroupTestFixtures.makeIdGenerator([GroupTestFixtures.memberId, GroupTestFixtures.eventId]),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        _ = try await groupStore.join(link: GroupInviteLink.make(groupId: GroupTestFixtures.groupId, code: "JOIN1234"), as: .anon, nickname: "Hiker")

        XCTAssertEqual(GroupTestURLProtocol.requests.map { $0.url?.path ?? "" }, [
            "/v3/groups/\(GroupTestFixtures.groupId)/join", "/v3/groups/\(GroupTestFixtures.groupId)/keys",
            "/v3/groups/\(GroupTestFixtures.groupId)", "/v3/groups/\(GroupTestFixtures.groupId)/events"
        ])
        let messageBody = try XCTUnwrap(identityEventBody)
        let payloadCipher = try XCTUnwrap(Data(base64Encoded: messageBody["payloadCipher"] as! String))
        let payload = try GroupCrypto.openMessage(
            payloadCipher, key: roomKey, groupId: GroupTestFixtures.groupId,
            memberId: joiningMemberId!, eventId: messageBody["eventId"] as! String, epoch: 1
        )
        XCTAssertEqual(payload.kind, .identity)
        XCTAssertEqual(payload.nickname, "Hiker")
        XCTAssertEqual(messageBody["epoch"] as? Int, 1)
    }

    @MainActor
    func testJoinAccountRequiresAccount() async {
        let groupStore = GroupStore(
            client: GroupTestFixtures.makeClient(), directory: StubGroupDirectory(signingKeys: [:]), secrets: secrets,
            rootDirectory: rootDirectory, localAccount: { nil },
            newId: { GroupTestFixtures.memberId }
        )

        do {
            _ = try await groupStore.join(link: GroupInviteLink.make(groupId: GroupTestFixtures.groupId, code: "JOIN1234"), as: .account, nickname: nil)
            XCTFail("expected accountRequired")
        } catch {
            XCTAssertEqual(error as? GroupError, .accountRequired)
        }
        XCTAssertTrue(GroupTestURLProtocol.requests.isEmpty)
    }

    @MainActor
    func testJoinWrongCodeKeepsNoLocalState() async throws {
        GroupTestURLProtocol.handler = { _ in GroupTestFixtures.json("{\"error\":\"bad_code\"}", status: 403) }
        let groupStore = store()

        do {
            _ = try await groupStore.join(link: GroupInviteLink.make(groupId: GroupTestFixtures.groupId, code: "BADCODE"), as: .account, nickname: nil)
            XCTFail("expected badCode")
        } catch {
            XCTAssertEqual(error as? GroupError, .badCode)
        }

        XCTAssertNil(secrets.identity(for: GroupTestFixtures.groupId))
        XCTAssertNil(secrets.roomKey(for: GroupTestFixtures.groupId, epoch: 1))
        XCTAssertTrue(groupStore.groups.isEmpty)
    }

    @MainActor
    func testJoinTransientErrorKeepsIdentity() async throws {
        GroupTestURLProtocol.handler = { _ in .init(status: 0, body: Data(), error: URLError(.timedOut)) }
        let groupStore = store()

        do {
            _ = try await groupStore.join(link: GroupInviteLink.make(groupId: GroupTestFixtures.groupId, code: "JOIN1234"), as: .account, nickname: nil)
            XCTFail("expected transport failure")
        } catch {
            XCTAssertEqual(error as? GroupError, .transient("transport_-1001"))
        }

        XCTAssertNotNil(secrets.identity(for: GroupTestFixtures.groupId))
    }

    @MainActor
    func testLeaveRemovesLocalKeysButKeepsNothingSecret() async throws {
        GroupTestURLProtocol.handler = { request in
            if request.url?.path == "/v3/groups" {
                return GroupTestFixtures.json("{\"groupId\":\"\(GroupTestFixtures.groupId)\",\"inviteCode\":\"JOIN1234\"}", status: 201)
            }
            return .init(status: 204, body: Data())
        }
        let groupStore = store()
        _ = try await groupStore.create(name: "Hike", description: nil, category: nil, joinPolicy: "accountOnly")
        XCTAssertNotNil(secrets.identity(for: GroupTestFixtures.groupId))
        XCTAssertNotNil(secrets.roomKey(for: GroupTestFixtures.groupId, epoch: 1))

        try await groupStore.leave(GroupTestFixtures.groupId)

        XCTAssertNil(secrets.identity(for: GroupTestFixtures.groupId))
        XCTAssertNil(secrets.roomKey(for: GroupTestFixtures.groupId, epoch: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootDirectory.appendingPathComponent(GroupTestFixtures.groupId).path))
        XCTAssertTrue(groupStore.groups.isEmpty)
        XCTAssertNil(groupStore.states[GroupTestFixtures.groupId])
    }

    @MainActor
    func testInviteLinkUsesSavedCodeAndRoundTrips() async throws {
        GroupTestURLProtocol.handler = { _ in
            GroupTestFixtures.json("{\"groupId\":\"\(GroupTestFixtures.groupId)\",\"inviteCode\":\"JOIN1234\"}", status: 201)
        }
        let groupStore = store()
        _ = try await groupStore.create(name: "Hike", description: nil, category: nil, joinPolicy: "accountOnly")

        let link = try XCTUnwrap(groupStore.inviteLink(for: GroupTestFixtures.groupId))
        let parsed = GroupInviteLink.parse(link)
        XCTAssertEqual(parsed?.groupId, GroupTestFixtures.groupId)
        XCTAssertEqual(parsed?.code, "JOIN1234")
    }
}
