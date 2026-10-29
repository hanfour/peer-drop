import Foundation
import CryptoKit
import XCTest
import PeerDropSecurity
import PeerDropAccount
@testable import PeerDropGroups

final class GroupSocketTests: XCTestCase {
    override func setUp() {
        super.setUp()
        GroupTestURLProtocol.reset()
    }

    override func tearDown() {
        GroupTestURLProtocol.reset()
        super.tearDown()
    }

    func testSendsExactTextPingEveryThirtySecondsAndIgnoresOtherFrames() async throws {
        let clock = ManualGroupSocketClock()
        let factory = FakeGroupWebSocketFactory()
        let observer = SocketObserver()
        let socket = makeSocket(factory: factory, clock: clock, observer: observer)

        await socket.start()
        await eventually { factory.socketCount == 1 }
        await eventually { await clock.hasSleeper(for: 30) }
        await clock.advance(by: 30)
        await eventually { factory.socket(at: 0)?.sentTexts == ["ping"] }

        let first = try XCTUnwrap(factory.socket(at: 0))
        first.push("pong")
        first.push("not an event")
        first.push(#"{"t":"other","e":{}}"#)
        first.push(#"{"t":"ev","e":{"seq":"bad"}}"#)
        await eventually { await clock.hasSleeper(for: 30) }
        await clock.advance(by: 30)
        await eventually { first.sentTexts == ["ping", "ping"] }

        let ignoredEvents = await observer.events
        XCTAssertTrue(ignoredEvents.isEmpty)
        XCTAssertEqual(first.sentTexts, ["ping", "ping"])
        await socket.stop()
    }

    func testValidEventFrameCallsOnEventOnce() async throws {
        let factory = FakeGroupWebSocketFactory()
        let observer = SocketObserver()
        let socket = makeSocket(factory: factory, observer: observer)
        await socket.start()
        await eventually { factory.socketCount == 1 }

        let event = sampleEvent()
        factory.socket(at: 0)?.push(try eventFrame(event))
        await eventually { await observer.events.count == 1 }

        let receivedEvents = await observer.events
        XCTAssertEqual(receivedEvents, [event])
        await socket.stop()
    }

    func testExpiredConnectionUsesFreshTicketAndRequestsBackfillAfterReconnect() async throws {
        let tickets = TicketSource([.ticket("first-ticket"), .ticket("second-ticket")])
        let clock = ManualGroupSocketClock()
        let factory = FakeGroupWebSocketFactory()
        let observer = SocketObserver()
        let socket = makeSocket(factory: factory, clock: clock, tickets: tickets, observer: observer)
        await socket.start()
        await eventually { factory.socketCount == 1 }
        factory.socket(at: 0)?.push("pong")
        factory.socket(at: 0)?.fail(GroupWebSocketFailure.closed(code: 4001))
        // The store uses the production jitter (+-25%), so match a range and advance past its upper bound.
        await eventually { await clock.hasSleeper(within: 0.75...1.25) }
        await clock.advance(by: 1.25)
        await eventually { factory.socketCount == 2 }
        factory.socket(at: 1)?.push("pong")
        await eventually { await observer.closeReasons == [.reconnected] }

        let requestCount = await tickets.requestCount
        XCTAssertEqual(requestCount, 2)
        let components = factory.urls.compactMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        XCTAssertEqual(components.map(\.scheme), ["wss", "wss"])
        XCTAssertEqual(components.map(\.path), Array(repeating: "/base/v3/groups/\(GroupTestFixtures.groupId)/ws", count: 2))
        XCTAssertEqual(components.compactMap { $0.queryItems?.first?.value }, ["first-ticket", "second-ticket"])
        await socket.stop()
    }

    func testReplacedConnectionReconnectsWithFreshTicket() async throws {
        let tickets = TicketSource([.ticket("first-ticket"), .ticket("second-ticket")])
        let clock = ManualGroupSocketClock()
        let factory = FakeGroupWebSocketFactory()
        let socket = makeSocket(factory: factory, clock: clock, tickets: tickets)
        await socket.start()
        await eventually { factory.socketCount == 1 }
        factory.socket(at: 0)?.fail(GroupWebSocketFailure.closed(code: 4000))
        await eventually { await clock.hasSleeper(for: 1) }
        await clock.advance(by: 1)
        await eventually { factory.socketCount == 2 }

        let requestCount = await tickets.requestCount
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(factory.urls.count, 2)
        await socket.stop()
    }

    func testRemovedCloseDoesNotReconnect() async throws {
        let clock = ManualGroupSocketClock()
        let factory = FakeGroupWebSocketFactory()
        let observer = SocketObserver()
        let socket = makeSocket(factory: factory, clock: clock, observer: observer)
        await socket.start()
        await eventually { factory.socketCount == 1 }
        factory.socket(at: 0)?.fail(GroupWebSocketFailure.closed(code: 4003))
        await eventually { await observer.closeReasons == [.removed] }
        await clock.advance(by: 600)
        await Task.yield()

        XCTAssertEqual(factory.socketCount, 1)
        let closeReasons = await observer.closeReasons
        XCTAssertEqual(closeReasons, [.removed])
        await socket.stop()
    }

    func testConnectionFailuresUseBoundedExponentialBackoff() async throws {
        let clock = ManualGroupSocketClock()
        let factory = FakeGroupWebSocketFactory()
        let tickets = TicketSource((0..<8).map { .ticket("ticket-\($0)") })
        let socket = makeSocket(factory: factory, clock: clock, tickets: tickets)
        let expected: [TimeInterval] = [1, 2, 4, 8, 16, 30, 30]

        await socket.start()
        await eventually { factory.socketCount == 1 }
        for (index, delay) in expected.enumerated() {
            factory.socket(at: index)?.fail(URLError(.networkConnectionLost))
            // Each cycle schedules one keepalive and one backoff sleep; the keepalive may also be 30 s, so wait
            // until the failed socket's keepalive is gone and only the backoff sleeper remains.
            await eventually {
                let counts = await clock.counts()
                return counts.scheduled == 2 * (index + 1) && counts.sleepers == 1
            }
            await eventually { await clock.hasSleeper(for: delay) }
            let scheduled = await clock.wasScheduled(within: delay * 0.75...delay * 1.25)
            XCTAssertTrue(scheduled)
            await clock.advance(by: delay)
            await eventually { factory.socketCount == index + 2 }
        }

        XCTAssertEqual(factory.socketCount, 8)
        let requestCount = await tickets.requestCount
        XCTAssertEqual(requestCount, 8)
        await socket.stop()
    }

    func testSuccessfulConnectionResetsBackoffToOneSecond() async throws {
        let clock = ManualGroupSocketClock()
        let factory = FakeGroupWebSocketFactory()
        let socket = makeSocket(factory: factory, clock: clock)
        await socket.start()
        await eventually { factory.socketCount == 1 }
        factory.socket(at: 0)?.fail(URLError(.networkConnectionLost))
        await eventually { await clock.hasSleeper(for: 1) }
        await clock.advance(by: 1)
        await eventually { factory.socketCount == 2 }
        factory.socket(at: 1)?.push("pong")
        await eventually { await clock.hasSleeper(for: 30) }
        factory.socket(at: 1)?.fail(URLError(.networkConnectionLost))
        await eventually { await clock.hasSleeper(for: 1) }

        let retriedQuickly = await clock.wasScheduled(within: 1...1)
        XCTAssertTrue(retriedQuickly)
        await socket.stop()
    }

    func testTransientTicketFailureRetriesAfterBackoff() async throws {
        let tickets = TicketSource([.failure(GroupError.transient("rate_limited")), .ticket("fresh-ticket")])
        let clock = ManualGroupSocketClock()
        let factory = FakeGroupWebSocketFactory()
        let socket = makeSocket(factory: factory, clock: clock, tickets: tickets)
        await socket.start()
        await eventually { await clock.hasSleeper(for: 1) }

        XCTAssertEqual(factory.socketCount, 0)
        await clock.advance(by: 1)
        await eventually { factory.socketCount == 1 }

        let requestCount = await tickets.requestCount
        XCTAssertEqual(requestCount, 2)
        await socket.stop()
    }

    func testNotMemberTicketFailureClosesAsRemoved() async throws {
        let tickets = TicketSource([.failure(GroupError.notMember)])
        let clock = ManualGroupSocketClock()
        let factory = FakeGroupWebSocketFactory()
        let observer = SocketObserver()
        let socket = makeSocket(factory: factory, clock: clock, tickets: tickets, observer: observer)
        await socket.start()
        await eventually { await observer.closeReasons == [.removed] }
        await clock.advance(by: 600)

        XCTAssertEqual(factory.socketCount, 0)
        let requestCount = await tickets.requestCount
        let closeReasons = await observer.closeReasons
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(closeReasons, [.removed])
        await socket.stop()
    }

    func testStopDuringBackoffPreventsReconnect() async throws {
        let clock = ManualGroupSocketClock()
        let factory = FakeGroupWebSocketFactory()
        let tickets = TicketSource([.ticket("first-ticket"), .ticket("second-ticket")])
        let socket = makeSocket(factory: factory, clock: clock, tickets: tickets)
        await socket.start()
        await eventually { factory.socketCount == 1 }
        factory.socket(at: 0)?.fail(URLError(.networkConnectionLost))
        await eventually { await clock.hasSleeper(for: 1) }

        await socket.stop()
        await clock.advance(by: 1)
        await Task.yield()

        XCTAssertEqual(factory.socketCount, 1)
        let requestCount = await tickets.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    @MainActor
    func testConnectTwiceCreatesOneSocketAndReconnectBackfills() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let encryptor = GroupTestFixtures.makeEncryptor()
        let secrets = GroupSecretsStore(directory: root.appendingPathComponent("secrets"), encryptor: encryptor)
        let signer = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x31, count: 32))
        let account = GroupStore.LocalAccount(accountId: GroupTestFixtures.accountId, signingPublicKey: signer.publicKey.rawRepresentation) { message in
            GroupCrypto.sign(message, with: signer)
        }
        let store = GroupStore(
            client: GroupTestFixtures.makeClient(), directory: StubGroupDirectory(signingKeys: [:]), secrets: secrets,
            rootDirectory: root.appendingPathComponent("groups"), localAccount: { account },
            newId: GroupTestFixtures.makeIdGenerator([GroupTestFixtures.groupId, GroupTestFixtures.memberId, GroupTestFixtures.eventId])
        )
        GroupTestURLProtocol.handler = { request in
            if request.url?.path == "/v3/groups" {
                return GroupTestFixtures.json("{\"groupId\":\"\(GroupTestFixtures.groupId)\",\"inviteCode\":\"JOIN1234\"}", status: 201)
            }
            if request.url?.path == "/v3/groups/\(GroupTestFixtures.groupId)/ws-ticket" {
                return GroupTestFixtures.json("{\"ticket\":\"one-time-ticket\"}")
            }
            return GroupTestFixtures.json("{}", status: 500)
        }
        _ = try await store.create(name: "Room", description: nil, category: nil, joinPolicy: "accountOnly")
        GroupTestURLProtocol.requests.removeAll()
        let factory = FakeGroupWebSocketFactory()
        let clock = ManualGroupSocketClock()
        store.liveSocketFactory = factory
        store.liveSocketClock = clock
        store.liveSocketBaseURL = URL(string: "https://worker.test")!
        GroupTestURLProtocol.handler = { request in
            if request.url?.path == "/v3/groups/\(GroupTestFixtures.groupId)/ws-ticket" {
                return GroupTestFixtures.json("{\"ticket\":\"one-time-ticket\"}")
            }
            if request.url?.path == "/v3/groups/\(GroupTestFixtures.groupId)" {
                let member = GroupTestFixtures.memberId
                let publicKey = Data(repeating: 0x41, count: 32).base64EncodedString()
                return GroupTestFixtures.json("""
                {"groupId":"\(GroupTestFixtures.groupId)","ownerMemberId":"\(member)","members":[{"memberId":"\(member)","kind":"account","accountId":"\(GroupTestFixtures.accountId)","joinedAt":1700000000000,"pubKey":"\(publicKey)","pubKeySig":null,"hasKey":true}],"joinPolicy":"accountOnly","state":"open","epoch":1,"seq":0,"firstSeq":1,"metaVersion":0,"rotationDue":false}
                """)
            }
            if request.url?.path == "/v3/groups/\(GroupTestFixtures.groupId)/events" {
                return GroupTestFixtures.json("{\"events\":[],\"firstSeq\":1}")
            }
            return GroupTestFixtures.json("{}", status: 500)
        }

        await store.connect(GroupTestFixtures.groupId)
        await store.connect(GroupTestFixtures.groupId)
        await eventually { factory.socketCount == 1 }

        XCTAssertEqual(factory.socketCount, 1)
        XCTAssertEqual(GroupTestURLProtocol.requests.filter { $0.url?.path.hasSuffix("/ws-ticket") == true }.count, 1)

        factory.socket(at: 0)?.push("pong")
        factory.socket(at: 0)?.fail(GroupWebSocketFailure.closed(code: 4001))
        // The store uses the production jitter (+-25%), so match a range and advance past its upper bound.
        await eventually { await clock.hasSleeper(within: 0.75...1.25) }
        await clock.advance(by: 1.25)
        await eventually { factory.socketCount == 2 }
        factory.socket(at: 1)?.push("pong")
        await eventually {
            GroupTestURLProtocol.requests.contains { $0.url?.path == "/v3/groups/\(GroupTestFixtures.groupId)/events" }
        }

        XCTAssertEqual(GroupTestURLProtocol.requests.filter { $0.url?.path == "/v3/groups/\(GroupTestFixtures.groupId)" }.count, 1)
        await store.disconnect(GroupTestFixtures.groupId)
    }

    @MainActor
    func testRemovedSocketCloseUsesStoreRemovalPath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let encryptor = GroupTestFixtures.makeEncryptor()
        let secrets = GroupSecretsStore(directory: root.appendingPathComponent("secrets"), encryptor: encryptor)
        let signer = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x31, count: 32))
        let account = GroupStore.LocalAccount(accountId: GroupTestFixtures.accountId, signingPublicKey: signer.publicKey.rawRepresentation) { message in
            GroupCrypto.sign(message, with: signer)
        }
        let store = GroupStore(
            client: GroupTestFixtures.makeClient(), directory: StubGroupDirectory(signingKeys: [:]), secrets: secrets,
            rootDirectory: root.appendingPathComponent("groups"), localAccount: { account },
            newId: GroupTestFixtures.makeIdGenerator([GroupTestFixtures.groupId, GroupTestFixtures.memberId, GroupTestFixtures.eventId])
        )
        GroupTestURLProtocol.handler = { request in
            if request.url?.path == "/v3/groups" {
                return GroupTestFixtures.json("{\"groupId\":\"\(GroupTestFixtures.groupId)\",\"inviteCode\":\"JOIN1234\"}", status: 201)
            }
            if request.url?.path == "/v3/groups/\(GroupTestFixtures.groupId)/ws-ticket" {
                return GroupTestFixtures.json("{\"ticket\":\"one-time-ticket\"}")
            }
            return GroupTestFixtures.json("{}", status: 500)
        }
        _ = try await store.create(name: "Room", description: nil, category: nil, joinPolicy: "accountOnly")
        GroupTestURLProtocol.requests.removeAll()
        let factory = FakeGroupWebSocketFactory()
        store.liveSocketFactory = factory
        store.liveSocketClock = ManualGroupSocketClock()
        store.liveSocketBaseURL = URL(string: "https://worker.test")!

        await store.connect(GroupTestFixtures.groupId)
        await eventually { factory.socketCount == 1 }
        factory.socket(at: 0)?.fail(GroupWebSocketFailure.closed(code: 4003))
        await eventually { store.groups.first?.state == .removed }

        XCTAssertTrue(store.states[GroupTestFixtures.groupId]?.supersededElsewhere == true)
        XCTAssertNotNil(secrets.identity(for: GroupTestFixtures.groupId))
        await store.disconnect(GroupTestFixtures.groupId)
    }

    private func makeSocket(
        factory: FakeGroupWebSocketFactory,
        clock: ManualGroupSocketClock = ManualGroupSocketClock(),
        tickets: TicketSource = TicketSource([.ticket("test-ticket")]),
        observer: SocketObserver = SocketObserver()
    ) -> GroupSocket {
        GroupSocket(
            groupId: GroupTestFixtures.groupId,
            baseURL: URL(string: "https://worker.test/base")!,
            ticket: { try await tickets.next() },
            factory: factory,
            onEvent: { event in Task { await observer.record(event) } },
            onClosed: { reason in Task { await observer.record(reason) } },
            clock: clock,
            jitter: { $0 }
        )
    }

    private func sampleEvent() -> WireEvent {
        WireEvent(
            seq: 1, eventId: "01ARZ3NDEKTSV4RRFFQ69G5FAX", type: "msg",
            authorMemberId: GroupTestFixtures.memberId, epoch: 1, payloadCipher: "cipher", createdAt: 1_700_000_000_000
        )
    }

    private func eventFrame(_ event: WireEvent) throws -> String {
        let eventData = try JSONEncoder().encode(event)
        let eventObject = try XCTUnwrap(JSONSerialization.jsonObject(with: eventData) as? [String: Any])
        let frame = try JSONSerialization.data(withJSONObject: ["t": "ev", "e": eventObject], options: [.sortedKeys])
        return String(decoding: frame, as: UTF8.self)
    }

    private func eventually(
        _ condition: @escaping () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        // Wall-clock polling (up to 5 s) because yields alone do not guarantee the socket actor has run.
        for _ in 0..<500 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Condition did not become true", file: file, line: line)
    }
}

private actor ManualGroupSocketClock: GroupSocketClock {
    private struct Sleeper {
        let deadline: TimeInterval
        let continuation: CheckedContinuation<Void, Error>
    }

    private var now: TimeInterval = 0
    private var sleepers: [UUID: Sleeper] = [:]
    private var scheduled: [TimeInterval] = []

    func sleep(for seconds: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                scheduled.append(seconds)
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    sleepers[id] = Sleeper(deadline: now + seconds, continuation: continuation)
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func advance(by seconds: TimeInterval) {
        now += seconds
        let ready = sleepers.filter { $0.value.deadline <= now }
        for (id, sleeper) in ready {
            sleepers[id] = nil
            sleeper.continuation.resume()
        }
    }

    func counts() -> (scheduled: Int, sleepers: Int) { (scheduled.count, sleepers.count) }

    func hasSleeper(within range: ClosedRange<TimeInterval>) -> Bool {
        sleepers.values.contains { range.contains($0.deadline - now) }
    }

    func hasSleeper(for seconds: TimeInterval) -> Bool {
        sleepers.values.contains { abs(($0.deadline - now) - seconds) < 0.001 }
    }

    func wasScheduled(within range: ClosedRange<TimeInterval>) -> Bool {
        scheduled.contains { range.contains($0) }
    }

    private func cancel(_ id: UUID) {
        guard let sleeper = sleepers.removeValue(forKey: id) else { return }
        sleeper.continuation.resume(throwing: CancellationError())
    }
}

private final class FakeGroupWebSocket: GroupWebSocket, @unchecked Sendable {
    private enum Result {
        case text(String)
        case failure(Error)
    }

    private let lock = NSLock()
    private var receiver: CheckedContinuation<String, Error>?
    private var received: [Result] = []
    private var sent: [String] = []
    var sentTexts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return sent
    }

    func send(text: String) async throws {
        appendSent(text)
        if text == "ping" { push("pong") }
    }

    private func appendSent(_ text: String) {
        lock.lock()
        sent.append(text)
        lock.unlock()
    }

    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            let next = received.isEmpty ? nil : received.removeFirst()
            if next == nil {
                receiver = continuation
            }
            lock.unlock()
            guard let next else { return }
            resume(continuation, with: next)
        }
    }

    func close() {
        fail(GroupWebSocketFailure.closed(code: 1000))
    }

    func push(_ text: String) {
        deliver(.text(text))
    }

    func fail(_ error: Error) {
        deliver(.failure(error))
    }

    private func deliver(_ result: Result) {
        lock.lock()
        let continuation = receiver
        receiver = nil
        if continuation == nil { received.append(result) }
        lock.unlock()
        if let continuation { resume(continuation, with: result) }
    }

    private func resume(_ continuation: CheckedContinuation<String, Error>, with result: Result) {
        switch result {
        case .text(let text): continuation.resume(returning: text)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}

private final class FakeGroupWebSocketFactory: GroupWebSocketFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var sockets: [FakeGroupWebSocket] = []
    private var madeURLs: [URL] = []

    var socketCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sockets.count
    }

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return madeURLs
    }

    func socket(at index: Int) -> FakeGroupWebSocket? {
        lock.lock()
        defer { lock.unlock() }
        return sockets.indices.contains(index) ? sockets[index] : nil
    }

    func make(url: URL) -> GroupWebSocket {
        let socket = FakeGroupWebSocket()
        lock.lock()
        sockets.append(socket)
        madeURLs.append(url)
        lock.unlock()
        return socket
    }
}

private actor TicketSource {
    enum Result {
        case ticket(String)
        case failure(GroupError)
    }

    private let results: [Result]
    private var index = 0

    init(_ results: [Result]) {
        self.results = results
    }

    var requestCount: Int { index }

    func next() throws -> String {
        defer { index += 1 }
        let result = results[min(index, results.count - 1)]
        switch result {
        case .ticket(let value): return value
        case .failure(let error): throw error
        }
    }
}

private actor SocketObserver {
    private(set) var events: [WireEvent] = []
    private(set) var closeReasons: [CloseReason] = []

    func record(_ event: WireEvent) { events.append(event) }
    func record(_ reason: CloseReason) { closeReasons.append(reason) }
}
