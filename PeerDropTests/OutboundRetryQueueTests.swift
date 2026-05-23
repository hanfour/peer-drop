import XCTest
@testable import PeerDrop

final class OutboundRetryQueueTests: XCTestCase {

    private var tmpURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".enc")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpURL)
        try await super.tearDown()
    }

    func test_enqueue_storesEntry() async throws {
        let queue = try await OutboundRetryQueue(storageURL: tmpURL)
        let entry = OutboundRetryQueue.Entry(
            id: UUID(),
            recipientMailboxId: "mailbox-123",
            payloadData: Data("hello".utf8),
            attemptCount: 0,
            firstAttemptAt: Date()
        )
        try await queue.enqueue(entry)
        let all = await queue.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.recipientMailboxId, "mailbox-123")
    }

    func test_enqueue_persistsAcrossReload() async throws {
        let entry = OutboundRetryQueue.Entry(
            id: UUID(),
            recipientMailboxId: "mb-1",
            payloadData: Data([0xAA, 0xBB, 0xCC]),
            attemptCount: 0,
            firstAttemptAt: Date()
        )
        do {
            let queue = try await OutboundRetryQueue(storageURL: tmpURL)
            try await queue.enqueue(entry)
        }
        // Different instance, same URL → must load existing entries.
        let reloaded = try await OutboundRetryQueue(storageURL: tmpURL)
        let all = await reloaded.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.payloadData, Data([0xAA, 0xBB, 0xCC]))
    }

    func test_remove_dropsEntry() async throws {
        let queue = try await OutboundRetryQueue(storageURL: tmpURL)
        let id = UUID()
        let entry = OutboundRetryQueue.Entry(
            id: id,
            recipientMailboxId: "mb-x",
            payloadData: Data(),
            attemptCount: 0,
            firstAttemptAt: Date()
        )
        try await queue.enqueue(entry)
        try await queue.remove(id: id)
        let all = await queue.all()
        XCTAssertEqual(all.count, 0)
    }

    func test_update_mutatesEntry() async throws {
        let queue = try await OutboundRetryQueue(storageURL: tmpURL)
        let id = UUID()
        let original = OutboundRetryQueue.Entry(
            id: id,
            recipientMailboxId: "mb-update",
            payloadData: Data(),
            attemptCount: 0,
            firstAttemptAt: Date()
        )
        try await queue.enqueue(original)

        var bumped = original
        bumped.attemptCount = 3
        try await queue.update(bumped)

        let all = await queue.all()
        XCTAssertEqual(all.first?.attemptCount, 3)
    }

    func test_emptyOnFirstLoad() async throws {
        let queue = try await OutboundRetryQueue(storageURL: tmpURL)
        let all = await queue.all()
        XCTAssertEqual(all.count, 0)
    }

    // MARK: - runRetryTick tests

    func test_retryTick_invokesCallback_perEntry() async throws {
        let queue = try await OutboundRetryQueue(storageURL: tmpURL)
        let e1 = OutboundRetryQueue.Entry(id: UUID(), recipientMailboxId: "a", payloadData: Data(), attemptCount: 0, firstAttemptAt: Date())
        let e2 = OutboundRetryQueue.Entry(id: UUID(), recipientMailboxId: "b", payloadData: Data(), attemptCount: 0, firstAttemptAt: Date())
        try await queue.enqueue(e1)
        try await queue.enqueue(e2)

        var attempted = 0
        await queue.runRetryTick { _ in
            attempted += 1
            return .success
        }
        XCTAssertEqual(attempted, 2)
        let remaining = await queue.all()
        XCTAssertEqual(remaining.count, 0, "successful entries should be removed")
    }

    func test_retryTick_failure_incrementsAttemptCount() async throws {
        let queue = try await OutboundRetryQueue(storageURL: tmpURL)
        let entry = OutboundRetryQueue.Entry(id: UUID(), recipientMailboxId: "a", payloadData: Data(), attemptCount: 0, firstAttemptAt: Date())
        try await queue.enqueue(entry)

        await queue.runRetryTick { _ in .failure }
        let updated = await queue.all().first
        XCTAssertEqual(updated?.attemptCount, 1)
    }

    func test_retryTick_alreadyRemoved_doesNotBumpCount() async throws {
        let queue = try await OutboundRetryQueue(storageURL: tmpURL)
        let entry = OutboundRetryQueue.Entry(id: UUID(), recipientMailboxId: "a", payloadData: Data(), attemptCount: 3, firstAttemptAt: Date())
        try await queue.enqueue(entry)

        await queue.runRetryTick { e in
            // Simulate the max-attempts-hit case: handler removes the entry itself
            try? await queue.remove(id: e.id)
            return .alreadyRemoved
        }
        let remaining = await queue.all()
        XCTAssertEqual(remaining.count, 0)
    }
}
