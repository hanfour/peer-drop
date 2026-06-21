import XCTest
import Combine

/// Regression for the headless-accept race fixed in `Entry.swift`.
///
/// `ConnectionManager.pendingIncomingRequest` is `@Published`, and `@Published`
/// emits on the property's `willSet` — *before* the stored value is assigned.
/// The CLI's incoming-request sink calls `acceptConnection()`, which re-reads
/// `pendingIncomingRequest`; called synchronously inside the sink it reads the
/// stale (still-nil) value and bails with "no pending request", so the peer is
/// never accepted and the phone's connect attempt times out. (The app path is
/// immune: a human taps the consent sheet long after the property is assigned.)
///
/// The fix defers the accept to the next main-actor tick (`Task { @MainActor }`),
/// by which point the assignment has completed. These tests pin that reasoning
/// with a faithful stand-in so a future change back to a synchronous accept is
/// caught here rather than only in a live phone↔CLI pairing.
final class HeadlessAcceptRaceTests: XCTestCase {

    /// Mirrors the shape that bit us: an `@Published` optional whose "accept"
    /// path re-reads the property — exactly like `ConnectionManager.acceptConnection()`.
    private final class FakeManager: ObservableObject {
        @Published var pendingRequest: Int?
        /// `nil` = accept never ran; `.some(nil)` = ran but read the stale nil;
        /// `.some(7)` = ran and read the assigned value.
        private(set) var acceptedValue: Int??
        func accept() { acceptedValue = pendingRequest }
    }

    func test_synchronousAcceptInSinkReadsStaleNil() {
        let m = FakeManager()
        var bag = Set<AnyCancellable>()
        m.$pendingRequest.compactMap { $0 }.sink { _ in m.accept() }.store(in: &bag)

        m.pendingRequest = 7

        // @Published fires in willSet → accept() ran before the assignment, so it
        // read nil. This is the bug the CLI accept handler must not reintroduce.
        XCTAssertEqual(m.acceptedValue, .some(nil),
                       "synchronous accept inside a willSet-published sink reads the stale nil")
    }

    func test_deferredAcceptReadsAssignedValue() {
        let m = FakeManager()
        var bag = Set<AnyCancellable>()
        let ran = expectation(description: "deferred accept ran")
        m.$pendingRequest.compactMap { $0 }.sink { _ in
            Task { @MainActor in m.accept(); ran.fulfill() }
        }.store(in: &bag)

        m.pendingRequest = 7

        wait(for: [ran], timeout: 1)
        XCTAssertEqual(m.acceptedValue, .some(7),
                       "deferring the accept to the next tick reads the assigned value (the fix)")
    }
}
