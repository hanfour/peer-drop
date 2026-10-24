import XCTest
@testable import PeerDropAccount

/// Scripted `AccountSettingsService`: returns what it is told, records every write.
private actor FakeSettings: AccountSettingsService {
    var stored: Bool
    var failure: Error?
    private(set) var writes: [Bool] = []
    init(stored: Bool = true, failure: Error? = nil) { self.stored = stored; self.failure = failure }
    func setFailure(_ e: Error?) { failure = e }
    func fetchNotePush() async throws -> Bool { if let failure { throw failure }; return stored }
    func updateNotePush(_ on: Bool) async throws -> Bool {
        writes.append(on)
        if let failure { throw failure }
        stored = on
        return on
    }
}

@MainActor
final class NotePushSettingTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "NotePushSettingTests-\(UUID().uuidString)")
    }

    func testDefaultsToOnWithNoCache() {
        let m = NotePushSetting(service: FakeSettings(), defaults: defaults)
        XCTAssertTrue(m.notePush)
    }

    func testRefreshAdoptsServerValueAndCachesIt() async {
        let m = NotePushSetting(service: FakeSettings(stored: false), defaults: defaults)
        await m.refresh()
        XCTAssertFalse(m.notePush)
        // a new model (e.g. next launch, offline) starts from the last known value
        let again = NotePushSetting(service: FakeSettings(stored: true, failure: AccountClientError.http(500)), defaults: defaults)
        XCTAssertFalse(again.notePush)
        await again.refresh()
        XCTAssertFalse(again.notePush, "a failed refresh must not change what is shown")
    }

    func testSetSucceedsAndPersists() async {
        let fake = FakeSettings()
        let m = NotePushSetting(service: fake, defaults: defaults)
        await m.set(false)
        XCTAssertFalse(m.notePush)
        XCTAssertNil(m.lastError)
        let writes = await fake.writes
        XCTAssertEqual(writes, [false])
        XCTAssertFalse(NotePushSetting(service: FakeSettings(), defaults: defaults).notePush)
    }

    func testFailedSetLeavesLocalStateAndCacheUnchanged() async {
        let fake = FakeSettings(stored: true, failure: AccountClientError.http(503))
        let m = NotePushSetting(service: fake, defaults: defaults)
        await m.set(false)
        XCTAssertTrue(m.notePush, "optimistic change must revert when the server call fails")
        XCTAssertNotNil(m.lastError)
        XCTAssertTrue(NotePushSetting(service: FakeSettings(failure: AccountClientError.http(503)), defaults: defaults).notePush, "cache untouched")
    }

    func testFailedSetFromOffRevertsToOff() async {
        let fake = FakeSettings(stored: false)
        let m = NotePushSetting(service: fake, defaults: defaults)
        await m.refresh()
        XCTAssertFalse(m.notePush)
        await fake.setFailure(AccountClientError.rateLimited)
        await m.set(true)
        XCTAssertFalse(m.notePush)
    }

    func testObservedValueIsOptimisticWhileRequestIsInFlight() async {
        let gate = GatedSettings()
        let m = NotePushSetting(service: gate, defaults: defaults)
        let task = Task { await m.set(false) }
        await gate.waitUntilWriteStarts()
        XCTAssertFalse(m.notePush, "UI flips immediately")
        XCTAssertTrue(m.isUpdating)
        await gate.release(result: .failure(AccountClientError.http(500)))
        await task.value
        XCTAssertTrue(m.notePush)
        XCTAssertFalse(m.isUpdating)
    }

    func testSecondSetWhileUpdatingIsIgnored() async {
        let gate = GatedSettings()
        let m = NotePushSetting(service: gate, defaults: defaults)
        let first = Task { await m.set(false) }
        await gate.waitUntilWriteStarts()
        await m.set(true)
        await gate.release(result: .success(false))
        await first.value
        XCTAssertFalse(m.notePush)
        let n = await gate.writeCount
        XCTAssertEqual(n, 1)
    }
}

/// Holds an update open until the test releases it.
private actor GatedSettings: AccountSettingsService {
    private var started: CheckedContinuation<Void, Never>?
    private var didStart = false
    private var finish: CheckedContinuation<Result<Bool, Error>, Never>?
    private(set) var writeCount = 0
    func fetchNotePush() async throws -> Bool { true }
    func updateNotePush(_ on: Bool) async throws -> Bool {
        writeCount += 1
        didStart = true
        started?.resume(); started = nil
        return try await withCheckedContinuation { finish = $0 }.get()
    }
    func waitUntilWriteStarts() async {
        if didStart { return }
        await withCheckedContinuation { started = $0 }
    }
    func release(result: Result<Bool, Error>) { finish?.resume(returning: result); finish = nil }
}
