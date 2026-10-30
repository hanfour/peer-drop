import Foundation
import CryptoKit
import XCTest
import PeerDropAccount
import PeerDropGroups
import PeerDropSecurity

private func makeCrockfordULID() -> String {
    let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    let first = alphabet[Int.random(in: 0..<8)]
    let remainder = (0..<25).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] }
    return String([first] + remainder)
}

@MainActor
final class GroupE2ETests: XCTestCase {
    private struct RegisteredAccount {
        let accountId: String
        let signingKey: Curve25519.Signing.PrivateKey
    }

    private struct RegistrationResponse: Decodable {
        let accountId: String
    }

    private struct ChallengeResponse: Decodable {
        let nonce: String
    }

    private struct MailboxResponse: Decodable {
        let token: String
    }

    private enum E2EFailure: Error {
        case invalidResponse
        case transport
        case status(Int)
        case timeout(String)
    }

    private struct Device {
        let client: GroupClient
        let secrets: GroupSecretsStore
        let store: GroupStore
    }

    func testThreeMemberGroupLifecycleEndToEnd() async throws {
        guard let baseURLValue = ProcessInfo.processInfo.environment["GROUP_E2E_BASE_URL"] else {
            throw XCTSkip("GROUP_E2E_BASE_URL not set")
        }
        guard let baseURL = URL(string: baseURLValue),
              baseURL.scheme == "http",
              let host = baseURL.host?.lowercased() else {
            XCTFail("GROUP_E2E_BASE_URL must be a local HTTP URL")
            return
        }
        guard host == "localhost" || host == "127.0.0.1" else {
            XCTFail("GROUP_E2E_BASE_URL host must be localhost or 127.0.0.1")
            return
        }

        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("GroupE2E-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        print("[GroupE2E] Step 1/8: registering account devices A and B")
        let deviceIdA = makeDeviceId("a")
        let deviceIdB = makeDeviceId("b")
        let deviceIdC = makeDeviceId("c")
        let accountA = try await registerAccount(baseURL: baseURL, deviceId: deviceIdA)
        let accountB = try await registerAccount(baseURL: baseURL, deviceId: deviceIdB)

        let accountClientA = try makeAccountClient(baseURL: baseURL, deviceId: deviceIdA)
        // The directory is account-scoped, so C uses A's client only to verify public signing keys.
        let directory = LiveGroupDirectory(account: accountClientA)
        let deviceA = makeDevice(
            deviceId: deviceIdA, directory: directory,
            accountClient: accountClientA, account: accountA,
            rootDirectory: temporaryRoot.appendingPathComponent("device-a", isDirectory: true)
        )
        let deviceB = makeDevice(
            deviceId: deviceIdB, directory: directory,
            accountClient: try makeAccountClient(baseURL: baseURL, deviceId: deviceIdB), account: accountB,
            rootDirectory: temporaryRoot.appendingPathComponent("device-b", isDirectory: true)
        )
        let deviceC = makeDevice(
            deviceId: deviceIdC, directory: directory,
            accountClient: try makeAccountClient(baseURL: baseURL, deviceId: deviceIdC, anonymous: true), account: nil,
            rootDirectory: temporaryRoot.appendingPathComponent("device-c", isDirectory: true)
        )

        print("[GroupE2E] Step 2/8: A creates a room that allows anonymous members")
        let groupId = try await deviceA.store.create(
            name: "Local group E2E", description: nil, category: "test", joinPolicy: "anonymousAllowed"
        )
        guard let inviteURL = deviceA.store.inviteLink(for: groupId),
              let invite = GroupInviteLink.parse(inviteURL) else {
            XCTFail("A did not retain its group invite link")
            return
        }

        print("[GroupE2E] Step 3/8: B joins as an account member and installs the first room key")
        let joinedB = try await deviceB.store.join(link: inviteURL, as: .account, nickname: nil)
        XCTAssertTrue(joinedB == groupId, "B joined the created group")
        try await eventually("B receives the first room key") {
            await deviceA.store.relayKeys(for: groupId)
            await deviceB.store.sync(groupId)
            return deviceB.secrets.roomKey(for: groupId, epoch: 1) != nil
        }
        guard let memberIdB = deviceB.store.states[groupId]?.myMemberId else {
            XCTFail("B has no local group identity")
            return
        }

        print("[GroupE2E] Step 4/8: C joins anonymously, installs a key, and posts an identity")
        let joinedC = try await deviceC.store.join(code: invite.code, as: .anon, nickname: "Guest C")
        XCTAssertTrue(joinedC == groupId, "C joined the created group")
        try await eventually("C receives the first room key") {
            await deviceA.store.relayKeys(for: groupId)
            await deviceC.store.sync(groupId)
            return deviceC.secrets.roomKey(for: groupId, epoch: 1) != nil
        }
        _ = try await deviceC.store.join(link: inviteURL, as: .anon, nickname: "Guest C")
        guard let memberIdC = deviceC.store.states[groupId]?.myMemberId else {
            XCTFail("C has no local group identity")
            return
        }
        try await eventually("the anonymous identity reaches all members") {
            await deviceA.store.sync(groupId)
            await deviceB.store.sync(groupId)
            await deviceC.store.sync(groupId)
            return [deviceA.store, deviceB.store, deviceC.store].allSatisfy { store in
                store.states[groupId]?.members.contains {
                    $0.memberId == memberIdC && $0.nickname == "Guest C"
                } == true
            }
        }

        print("[GroupE2E] Step 5/8: all three members exchange decryptable messages")
        let initialMessages = ["A: hello", "B: hello", "C: hello"]
        try await deviceA.store.send(groupId, text: initialMessages[0])
        try await deviceB.store.send(groupId, text: initialMessages[1])
        try await deviceC.store.send(groupId, text: initialMessages[2])
        try await eventually("all members decrypt the three messages") {
            var allReceived = true
            for device in [deviceA, deviceB, deviceC] {
                await device.store.sync(groupId)
                let received = Set(device.store.states[groupId]?.messages.map(\.text) ?? [])
                if !Set(initialMessages).isSubset(of: received) { allReceived = false }
            }
            return allReceived
        }

        print("[GroupE2E] Step 6/8: B catches up on A's message after being offline")
        let offlineMessage = "A: while B is offline"
        try await deviceA.store.send(groupId, text: offlineMessage)
        try await eventually("B backfills A's offline message") {
            await deviceB.store.sync(groupId)
            return deviceB.store.states[groupId]?.messages.contains { $0.text == offlineMessage } == true
        }

        print("[GroupE2E] Step 7/8: A removes C and rotates the room key")
        try await deviceA.store.kick(groupId, memberId: memberIdC)
        try await eventually("B installs the rotated room key") {
            await deviceB.store.sync(groupId)
            return deviceB.store.states[groupId]?.epoch == 2 &&
                deviceB.secrets.roomKey(for: groupId, epoch: 2) != nil
        }
        try await eventually("C is marked as removed") {
            await deviceC.store.sync(groupId)
            return deviceC.store.states[groupId]?.state == .removed
        }
        XCTAssertTrue(
            deviceC.secrets.roomKey(for: groupId, epoch: 2) == nil,
            "C has no room key for the rotated epoch"
        )

        let rotatedMessage = "A: after the kick"
        try await deviceA.store.send(groupId, text: rotatedMessage)
        try await eventually("B decrypts a message from the rotated epoch") {
            await deviceB.store.sync(groupId)
            return deviceB.store.states[groupId]?.messages.contains { $0.text == rotatedMessage } == true
        }
        guard let memberIdA = deviceA.store.states[groupId]?.myMemberId,
              let bRoomKey = deviceB.secrets.roomKey(for: groupId, epoch: 2),
              let cOldRoomKey = deviceC.secrets.roomKey(for: groupId, epoch: 1) else {
            XCTFail("A member identity or expected room key is missing")
            return
        }
        let events = try await deviceB.client.events(id: groupId, memberId: memberIdB, since: 0)
        guard let event = events.events.first(where: {
            $0.type == "msg" && $0.authorMemberId == memberIdA && $0.epoch == 2 && $0.payloadCipher != nil
        }), let cipher = event.payloadCipher.flatMap({ Data(base64Encoded: $0) }) else {
            XCTFail("B cannot find A's encrypted message from the rotated epoch")
            return
        }
        let decodedForB = try GroupCrypto.openMessage(
            cipher, key: bRoomKey, groupId: groupId, memberId: memberIdA,
            eventId: event.eventId, epoch: event.epoch
        )
        XCTAssertTrue(decodedForB.text == rotatedMessage, "B decrypts the rotated-epoch message")
        XCTAssertThrowsError(try GroupCrypto.openMessage(
            cipher, key: cOldRoomKey, groupId: groupId, memberId: memberIdA,
            eventId: event.eventId, epoch: event.epoch
        ), "C cannot decrypt the rotated-epoch message")

        print("[GroupE2E] Step 8/8: C is blocked from rejoining and B reads history after A closes")
        do {
            _ = try await deviceC.store.join(link: inviteURL, as: .anon, nickname: "Guest C")
            XCTFail("C rejoined with a banned device")
        } catch let error as GroupError {
            XCTAssertTrue(error == .banned, "the server rejects C's kicked device as banned")
        }

        try await deviceA.store.close(groupId)
        let history = initialMessages + [offlineMessage, rotatedMessage]
        try await eventually("B keeps readable history after the room closes") {
            await deviceB.store.sync(groupId)
            guard let state = deviceB.store.states[groupId] else { return false }
            return state.state == .closed && Set(history).isSubset(of: Set(state.messages.map(\.text)))
        }
    }

    private func registerAccount(baseURL: URL, deviceId: String) async throws -> RegisteredAccount {
        let headers = [
            "X-API-Key": "local-dev-api-key",
            "X-Device-Id": deviceId,
            "Content-Type": "application/json"
        ]
        let signingKey = Curve25519.Signing.PrivateKey()
        let identityKey = randomBytes(count: 32)
        let mailboxId = "mbx" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

        let mailboxData = try await postJSON(
            path: "v2/keys/register", baseURL: baseURL, headers: headers,
            body: ["mailboxId": mailboxId, "preKeyBundle": [String: String]()]
        )
        let mailbox = try decode(MailboxResponse.self, from: mailboxData)

        let challengeData = try await postJSON(
            path: "v3/account/challenge", baseURL: baseURL, headers: headers,
            body: ["deviceId": deviceId]
        )
        let challenge = try decode(ChallengeResponse.self, from: challengeData)
        guard let nonce = Data(base64Encoded: challenge.nonce), nonce.count == 32 else {
            throw E2EFailure.invalidResponse
        }

        var boundInput = identityKey
        boundInput.append(contentsOf: mailboxId.utf8)
        let bound = Data(SHA256.hash(data: boundInput))
        var signedMessage = Data("peerdrop-account-v2".utf8)
        signedMessage.append(nonce)
        signedMessage.append(contentsOf: deviceId.utf8)
        signedMessage.append(bound)
        let signature = try signingKey.signature(for: signedMessage)

        let registrationData = try await postJSON(
            path: "v3/account/register", baseURL: baseURL, headers: headers,
            body: [
                "deviceId": deviceId,
                "platform": "macos",
                "identityKey": identityKey.base64EncodedString(),
                "signingKey": signingKey.publicKey.rawRepresentation.base64EncodedString(),
                "mailboxId": mailboxId,
                "mailboxToken": mailbox.token,
                "nonce": nonce.base64EncodedString(),
                "signature": signature.base64EncodedString()
            ]
        )
        let registration = try decode(RegistrationResponse.self, from: registrationData)
        return RegisteredAccount(accountId: registration.accountId, signingKey: signingKey)
    }

    private func makeAccountClient(baseURL: URL, deviceId: String, anonymous: Bool = false) throws -> AccountClient {
        let token = try anonymous ? makeLocalDeviceToken(deviceId: deviceId) : nil
        return AccountClient(
            baseURL: baseURL,
            authProvider: { request in
                if let token {
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                } else {
                    request.setValue("local-dev-api-key", forHTTPHeaderField: "X-API-Key")
                }
                request.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
            },
            tokenInvalidator: {}
        )
    }

    private func makeLocalDeviceToken(deviceId: String) throws -> String {
        let payload = try JSONSerialization.data(withJSONObject: [
            "deviceId": deviceId,
            "scope": "default",
            "expires": Int(Date().timeIntervalSince1970) + 900
        ])
        let signature = HMAC<SHA256>.authenticationCode(
            for: payload, using: SymmetricKey(data: Data("local-dev-secret-0123456789".utf8))
        )
        func base64URL(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        return base64URL(payload) + "." + base64URL(Data(signature))
    }

    private func makeDevice(
        deviceId: String,
        directory: GroupDirectory,
        accountClient: AccountClient,
        account: RegisteredAccount?,
        rootDirectory: URL
    ) -> Device {
        let client = GroupClient(account: accountClient)
        let encryptor = ChatDataEncryptor(testKey: SymmetricKey(size: .bits256))
        let secrets = GroupSecretsStore(
            directory: rootDirectory.appendingPathComponent("secrets", isDirectory: true), encryptor: encryptor
        )
        let localAccount = account.map { registered in
            GroupStore.LocalAccount(
                accountId: registered.accountId,
                signingPublicKey: registered.signingKey.publicKey.rawRepresentation
            ) { message in
                try registered.signingKey.signature(for: message)
            }
        }
        let store = GroupStore(
            client: client,
            directory: directory,
            secrets: secrets,
            rootDirectory: rootDirectory.appendingPathComponent("groups", isDirectory: true),
            localAccount: { localAccount },
            newId: makeCrockfordULID
        )
        return Device(client: client, secrets: secrets, store: store)
    }

    private func postJSON(
        path: String,
        baseURL: URL,
        headers: [String: String],
        body: [String: Any]
    ) async throws -> Data {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = "/" + path
        guard let url = components?.url else { throw E2EFailure.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw E2EFailure.transport
        }
        guard let http = response as? HTTPURLResponse else { throw E2EFailure.invalidResponse }
        guard http.statusCode == 201 else { throw E2EFailure.status(http.statusCode) }
        return data
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw E2EFailure.invalidResponse
        }
    }

    private func eventually(
        _ description: String,
        attempts: Int = 24,
        check: @MainActor () async -> Bool
    ) async throws {
        for attempt in 0..<attempts {
            if await check() { return }
            if attempt + 1 < attempts {
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        throw E2EFailure.timeout(description)
    }

    private func makeDeviceId(_ label: String) -> String {
        "group-e2e-\(label)-\(UUID().uuidString.lowercased())"
    }

    private func randomBytes(count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

}
