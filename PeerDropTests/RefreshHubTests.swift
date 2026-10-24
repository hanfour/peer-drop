import XCTest
import Combine
@testable import PeerDrop

final class RefreshHubTests: XCTestCase {
    private final class Source: ObservableObject {
        @Published var value = 0
    }

    /// objectWillChange fires before the write; a single isolated change must still be seen post-mutation.
    func testSingleIsolatedChangeIsObservedAfterMutation() {
        let source = Source()
        var seen: [Int] = []
        let exp = expectation(description: "refresh")
        let c = RefreshHub.pipeline([source.objectWillChange.map { _ in () }.eraseToAnyPublisher()])
            .sink { seen.append(source.value); exp.fulfill() }
        source.value = 42
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(seen, [42])
        c.cancel()
    }
}
